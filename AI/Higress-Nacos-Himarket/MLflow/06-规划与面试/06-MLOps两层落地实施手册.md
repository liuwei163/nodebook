# 离线 K8s 集群 MLOps 两层落地实施手册

> 适用场景：离线/内网 K8s，已用 kthena 部署 DeepSeek-32B（distill-Qwen），已有 Harbor、GitLab、Jenkins/ArgoCD、Higress、Prometheus。
> 目标：第一层把推理做到「有数据可讲」的专业级；第二层跑通一次完整的模型迭代闭环。
> 所有 YAML 中的 `<...>` 为待替换占位符。
>
> ⚠ **文档定位与勘误（2026-11-13）**：本手册是**规划蓝本**（写作时面向 NVIDIA
> 假想环境；实际落地环境为昇腾 910B + vllm-ascend，实测差异见
> 《DeepSeek-32B-推理性能实测报告》与《DeepSeek-32B-推理优化-面试材料》）。
> 其中两处技术口径已被后续实测推翻，以实测文档为准：
> ① `--allowed-hosts` 相关表述（见 3.5 节与坑 4 的勘误注记）；
> ② NFS 挂载参数建议（见 1.3 节与坑 11 的勘误注记）。


---

## 0. 阅读方式

- 第 1 章是**必须先做的地基**，不做的话后面每一步都会卡住。
- 第 2 章是 4 个独立实验，顺序建议按 A→B→C→D，因为 D 是第 3 章的技术前提。
- 第 3 章是闭环，依赖第 2 章的 D 和地基里的模型制品存储（NFS 或 MinIO）。
- 第 5 章的坑清单建议先扫一遍，能省掉大量试错。

---

## 1. 全局前提

### 1.1 命名空间划分

| Namespace | 内容 | 说明 |
|---|---|---|
| `ml-serving` | ModelServing / ModelServer / ModelRoute / AutoScalingPolicy | 推理面，GPU 主要消耗方 |
| `ml-platform` | MLflow、Argo Workflows、MinIO（可选） | 控制面，不占 GPU |
| `ml-train` | 训练 Job / Argo Workflow 实例 | 必须加 ResourceQuota，防止训练把 GPU 吃干 |

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ml-train-quota
  namespace: ml-train
spec:
  hard:
    requests.nvidia.com/gpu: "1"      # 训练与推理错峰，任何时刻训练最多占 1 卡
    requests.cpu: "16"
    requests.memory: 64Gi
```

这个 quota 不只是限制，它本身就是一个很好的工程细节：**它强制训练和线上推理错峰**，你面试时可以讲「我用 ResourceQuota 把训练负载限制在推理之外的资源窗口里，避免 OOM Killer 打到正在服务的 vLLM」。

### 1.2 显存预算表（DeepSeek-R1-Distill-Qwen-32B）

| 精度 | 权重占用 | 单卡能否跑 | 建议 TP | 备注 |
|---|---|---|---|---|
| BF16 | ~65 GB | 80G 单卡勉强，KV 空间不足 | 2 | 基线，必须有一组 |
| FP8 | ~33 GB | 单 80G 可，单 48G 勉强 | 1~2 | 需要 sm89+（L20/L40S/H100），零成本方案 |
| AWQ W4A16 | ~19 GB | 单 48G 可 | 1 | 吞吐/质量权衡最好的一组 |
| GPTQ W4A16 | ~19 GB | 单 48G 可 | 1 | 与 AWQ 对比用 |

> 先 `nvidia-smi` 确认卡型和数量，再决定 A 实验能做几组。卡不够就砍掉 GPTQ，保留 BF16 / FP8 / AWQ 三组，结论一样成立。

### 1.3 地基层：模型制品存储（NFS 或 MinIO，二选一）

**这一步必须先做**，因为 kthena 的 `modelURI` 和 `loraAdapters.artifactURL` 都支持从外部存储直接拉取。存储一通，第二层的「adapter 怎么进 Pod」问题自动消失——**不需要 initContainer，也不需要打镜像**。

kthena 支持的 scheme（字段细节以 `kubectl explain modelbooster.spec.modelURI` 为准）：

| scheme | 说明 | 适用 |
|---|---|---|
| `pvc://` | 挂载已有 PVC | **有 NFS / 共享存储时首选** |
| `s3://` | S3 兼容对象存储 | 有 MinIO / OSS / Ceph RGW |
| `obs://` | 华为 OBS | 公有云场景 |
| `hf://` | HuggingFace | 离线不可用 |
| `hostpath://` | 节点本地目录 | 只作二级缓存，跨节点失效 |

**已有 NFS 就不必为此装 MinIO**，三个理由：

1. NFS 的 PVC 天然是 `ReadWriteMany`，多副本、多节点挂同一份权重——这正是推理扩容需要的。`hostpath://` 在副本漂移到别的节点时会重新下载 65GB。
2. `pvc://` 和 `s3://` 都是一行 YAML，工程量没有差异。
3. 少一个组件 = 少一个故障点、少一个要同步进 Harbor 的镜像、少一套要维护的凭据。

你会失去的只有两样，且都能弥补：

- **对象不可变**（S3 天然防篡改）→ 用 `sha256sum` 校验和 + 目录只读约定弥补；
- **Argo 原生 artifact 传递**（Argo 的 artifactRepository 不支持 PVC）→ 用 `volumeMounts` 共享卷 + `archive: none` 代替，见 3.6。

#### 方案 A：NFS（推荐，你已有）

先确认 StorageClass 支持 RWX：

```bash
kubectl get sc
kubectl get sc <nfs-sc> -o yaml | grep -A5 mountOptions
```

三个 PVC（文件系统没有「桶」的隔离，靠目录约定管住）：

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: model-weights, namespace: ml-serving }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: <nfs-sc>
  resources: { requests: { storage: 500Gi } }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: adapters, namespace: ml-serving }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: <nfs-sc>
  resources: { requests: { storage: 100Gi } }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: mlflow-artifacts, namespace: ml-platform }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: <nfs-sc>
  resources: { requests: { storage: 200Gi } }
```

NFS 上的目录结构：

```
/mnt/nfs/ml/
├── models/
│   ├── DeepSeek-R1-Distill-Qwen-32B/        # BF16 基座 ~65GB
│   ├── DeepSeek-R1-Distill-Qwen-32B-AWQ/    # INT4 ~19GB
│   └── Qwen2.5-7B-Instruct/                 # 3.4 用的 judge 模型
├── adapters/
│   ├── tenant-a/
│   └── alert2json-v1/
└── mlflow/                                   # MLflow artifact store
```

模型入库（比 `mc cp` 朴素，但够用）：

```bash
rsync -av --progress /data/DeepSeek-R1-Distill-Qwen-32B/ /mnt/nfs/ml/models/DeepSeek-R1-Distill-Qwen-32B/
cd /mnt/nfs/ml/models/DeepSeek-R1-Distill-Qwen-32B && sha256sum *.safetensors > SHA256SUMS
```

ModelBooster 改成 `pvc://`：

```yaml
spec:
  modelURI: "pvc://model-weights/DeepSeek-R1-Distill-Qwen-32B"
  cacheURI: "pvc://model-cache/DeepSeek-R1-Distill-Qwen-32B"
  # 不需要 envFrom / ENDPOINT，没有 S3 凭据
```

> `pvc://` 是否支持 `<pvc名>/<子路径>` 这种写法随版本可能不同，用 `kubectl explain modelbooster.spec.modelURI` 的字段描述确认；若不支持子路径，就把 PVC 直接挂到模型目录的上一级。

**NFS 必须先量两件事**：

1. **挂载参数决定加载时间。** 默认 mount 参数下 65GB 权重可能要加载 15 分钟；加上大 rsize/wsize + nfsvers=4.1，万兆网能降到 1~2 分钟：
   ```yaml
   mountOptions: [nfsvers=4.1, rsize=1048576, wsize=1048576, hard, timeo=600, retrans=2, noresvport]
   ```
   > ⚠ **勘误（2026-11-13，以实测为准）**：本集群 NFS 服务端**只支持 NFSv3**
   > （`vers=4.1` 挂载直接失败），且服务端未开 NLM 锁、附加参数一多即报
   > `access denied by server`——mlflow PV 最终实测可用配置是 `vers=3 + nolock`
   > 两个参数，详见《MLflow-离线部署与模型登记》坑 2/坑 3。"先量基线"的方法论
   > 本身仍然有效，但参数上限要按服务端实际支持来定。
   这个数字直接决定 L1-C 里新副本的冷启动时间，**先测一次基线**：
   ```bash
   time cat /mnt/nfs/ml/models/DeepSeek-R1-Distill-Qwen-32B/*.safetensors > /dev/null
   ```
2. **NFS 断连会让 Pod 卡死。** `hard` 挂载在服务器无响应时无限重试，现象是 vLLM 加载到一半挂起、但日志里没有报错。排查先看 `kubectl describe pod` 的 Events 里有没有 `nfs: server not responding`。

#### 方案 B：MinIO（可选，需要 S3 语义时）

后续如果要做「对象不可变 + 版本化路径 + 多集群共享」，再在 NFS 之上叠一个 MinIO（MinIO 的 PV 直接用 NFS PVC）。代价是 MinIO 官方不建议把 NFS 当数据盘（xattr 与 fsync 语义有差异），只适合制品这种低频写场景，不要放高频小文件。

```yaml
# minio.yaml（ml-platform）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ml-platform
spec:
  replicas: 1
  selector:
    matchLabels: { app: minio }
  template:
    metadata:
      labels: { app: minio }
    spec:
      containers:
        - name: minio
          image: <harbor>/infra/minio:RELEASE.2025-04-22T22-12-26Z
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              valueFrom: { secretKeyRef: { name: minio-root, key: user } }
            - name: MINIO_ROOT_PASSWORD
              valueFrom: { secretKeyRef: { name: minio-root, key: password } }
          ports:
            - { containerPort: 9000, name: s3 }
            - { containerPort: 9001, name: console }
          volumeMounts:
            - { name: data, mountPath: /data }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: minio-data }
```

建桶（用 `mc` 或在 console 点）：

```bash
mc alias set local http://minio.ml-platform:9000 <user> <pass>
mc mb local/models local/mlflow local/adapters
```

**上传模型权重**（在能访问存储的跳板机上）：

```bash
mc cp -r /data/DeepSeek-R1-Distill-Qwen-32B local/models/
mc cp -r /data/DeepSeek-R1-Distill-Qwen-32B-AWQ local/models/
mc du local/models/DeepSeek-R1-Distill-Qwen-32B   # 确认 ~65GB 完整
```

**给 kthena 的 S3 凭据 Secret**：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-s3-cred
  namespace: ml-serving
stringData:
  ACCESS_KEY: "<user>"
  SECRET_KEY: "<pass>"
  ENDPOINT: "http://minio.ml-platform:9000"
```

**验证是不是通了**——先发一版最简单的 ModelBooster，确认从 S3 拉起成功，再往下做实验：

```yaml
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: ModelBooster
metadata:
  name: ds32b-smoke
  namespace: ml-serving
spec:
  name: ds32b-smoke
  owner: ml-team
  backend:
    name: ds32b-smoke-vllm
    type: vLLM
  modelURI: "s3://models/DeepSeek-R1-Distill-Qwen-32B"
  cacheURI: "pvc://model-cache"          # 不要用 hostpath，见第 5 章坑 3
  envFrom:
    - secretRef: { name: minio-s3-cred }
  env:
    - name: ENDPOINT
      value: "http://minio.ml-platform:9000"
  minReplicas: 1
  maxReplicas: 1
  workers:
    - type: server
      image: <harbor>/ml/vllm-openai:v0.8.5
      replicas: 1
      pods: 1
      resources:
        limits: { nvidia.com/gpu: "2", memory: 128Gi, cpu: "16" }
```

```bash
kubectl get modelserving,modelbooster,pod -n ml-serving -w
kubectl get modelserving ds32b-smoke -n ml-serving -o jsonpath='{.status.conditions}' | jq
# Available=True 就可以发请求了
```

---

## 2. 第一层：推理专业化（4 个实验）

每个实验的产出格式统一为：**假设 → 变量 → 原始数据 → 一张图 → 一句结论**。这个格式是第二层 MLflow 记录规范的原型，也是你面试能直接复用的叙事结构。

### 2.1 实验 L1-A：量化对比（BF16 / FP8 / AWQ / GPTQ）

**假设**：INT4 量化能把单卡部署门槛从 2 卡降到 1 卡，吞吐提升 1.5~2.5 倍，代价是 golden set 准确率下降 1~3 个百分点。

**关键：唯一变量原则。** 下列参数必须在 4 组之间完全一致，否则数据不可比：

| 参数 | 固定值 | 为什么必须固定 |
|---|---|---|
| `--max-model-len` | 4096 | 影响 KV cache 分配和 batch 上限 |
| `--gpu-memory-utilization` | 0.90 | 显存不同 → KV 块数不同 → 吞吐不可比 |
| `--max-num-seqs` | 32 | 并发上限，直接决定吞吐天花板 |
| prefix caching | 显式开启或关闭 | **vLLM 0.6+ 默认开启**，不固定会得到假数据 |
| chunked prefill | 显式设定 | V1 默认开启，同样会污染对比 |
| TP | 按 1.2 表 | TP 变化会改变通信开销 |

**权重来源三条路（按省事程度排序）**：

1. **FP8（推荐先做）**：不需要预量化权重，直接用 BF16 权重 + vLLM 在线 FP8：
   ```
   --quantization fp8 --dtype bfloat16
   ```
   前提是卡支持 sm89+。这一步 10 分钟就能出结果，是无本买卖。
2. **社区量化权重**：跳板机下载 `casperhansen/deepseek-r1-distill-qwen-32b-awq` 之类，`mc cp` 上传。注意核对 `config.json` 里的 `quantization_config`。
3. **自己量化**：`AutoAWQ` 或 `llm-compressor`，32B 在单卡上约 3~6 小时，准备 512 条校准样本。只有前两条都走不通才做这个——它本身不是你要学的重点。

**压测命令**（`vllm bench serve`，0.8+ 内置）：

```bash
for Q in bf16 fp8 awq gptq; do
  for C in 1 4 8 16 32; do
    vllm bench serve \
      --backend openai-chat \
      --base-url http://<router-svc>.ml-serving:80 \
      --endpoint /v1/chat/completions \
      --model ds32b-${Q} \
      --tokenizer /models/DeepSeek-R1-Distill-Qwen-32B \
      --dataset-name random \
      --random-input-len 1024 \
      --random-output-len 256 \
      --num-prompts 200 \
      --max-concurrency ${C} \
      --request-rate inf \
      --percentile-metrics ttft,tpot,itl,e2el \
      --save-result --result-dir /results/${Q}-c${C}
  done
done
```

三个必须注意的点：

- `--tokenizer` 必须指向**本地路径**。用 `--dataset-name random` 时 bench 仍要加载 tokenizer 来生成 token 序列，默认会去 HuggingFace 拉，离线环境直接卡死。
- `--request-rate inf` 是饱和压测（打满），想看排队行为时要改成有限值（见 L1-C）。
- `--save-result` 输出的 json 直接喂给 MLflow，别手工抄数字。

**质量侧的对照**（不能只看吞吐）：

```bash
# 用固定的 200 条 golden set 跑一遍，规则打分
python eval/run_eval.py \
  --base-url http://<router-svc>.ml-serving:80 \
  --models ds32b-bf16,ds32b-fp8,ds32b-awq,ds32b-gptq \
  --dataset eval/golden_200.jsonl \
  --out /results/quality.json
```

**产出表格长这样**（数字示例，你要填真实值）：

| 精度 | 卡数 | TTFT p50 @c=1 | TTFT p50 @c=32 | 输出 tok/s @c=32 | 峰值显存 | golden 准确率 |
|---|---|---|---|---|---|---|
| BF16 | 2 | 0.42s | 2.9s | 310 | 76GB | 88.5% |
| FP8 | 1 | 0.38s | 2.1s | 470 | 44GB | 88.0% |
| AWQ | 1 | 0.35s | 1.6s | 620 | 31GB | 86.2% |

**结论范式**（面试时这么讲）：「AWQ 在 c=32 下吞吐是 BF16 的 2.0 倍、显存降到 41%，但结构化输出任务的准确率掉了 2.3 个点，主要体现在数值抽取上，所以我们最终选 FP8——它用一半的卡拿到 1.5 倍吞吐，质量只掉 0.5 个点。」这个结论比「我部署了量化模型」有信息量得多。

⚠️ 量化模型的 tokenizer / chat template 必须与基座完全一致，否则准确率差异里混进了 prompt 格式差异，实验直接作废。

### 2.2 实验 L1-B：PD 分离前后对比

**假设**：PD 分离在长输入场景能显著降 TTFT，在短输入长输出场景反而变差。

**基线**：单 Role、单 ModelServing、TP=2。

**实验组**：两 Role（prefill / decode）+ ModelServer 的 `pdGroup` + `kvConnector`。

```yaml
# ModelServer，关键在 pdGroup
apiVersion: networking.serving.volcano.sh/v1alpha1
kind: ModelServer
metadata:
  name: ds32b-pd
  namespace: ml-serving
spec:
  model: "ds32b-pd"
  inferenceEngine: vLLM
  workloadPort: { port: 8000 }
  kvConnector:
    type: nixl
  workloadSelector:
    matchLabels:
      modelserving.volcano.sh/name: ds32b-pd
  pdGroup:
    groupKey: "modelserving.volcano.sh/group-name"
    prefillLabels:
      modelserving.volcano.sh/role: prefill
    decodeLabels:
      modelserving.volcano.sh/role: decode
  trafficPolicy:
    timeout: 60s
    retry: { attempts: 2 }
```

ModelServing 里两个 Role，各自的启动参数要分开调：

| 角色 | 关键参数 | 取值逻辑 |
|---|---|---|
| prefill | `--max-num-batched-tokens` | 调大（如 8192），吃满算力，prefill 是 compute-bound |
| prefill | `--max-num-seqs` | 可以小，prefill 不长期持有请求 |
| decode | `--max-num-seqs` | 调大（如 64），decode 是 memory-bound，靠并发换吞吐 |
| decode | `--block-size` | 与 KV 传输对齐，nixl 场景注意块大小一致性 |

**测试矩阵（这是实验的灵魂）**：只测一种输入长度是没有意义的，必须做 2×2：

| 场景 | input_len | output_len | 预期 |
|---|---|---|---|
| 长输入短输出（RAG/摘要） | 4096 | 64 | PD 明显收益，TTFT 降 30%+ |
| 短输入长输出（对话/生成） | 128 | 1024 | PD 收益接近零甚至为负 |
| 均衡 | 1024 | 256 | 小幅收益 |
| 超长输入（文档处理） | 8192 | 32 | PD 收益最大，但受 KV 传输带宽限制 |

```bash
for S in "4096 64" "128 1024" "1024 256"; do
  set -- $S
  vllm bench serve --backend openai-chat \
    --base-url http://<router-svc>.ml-serving:80 \
    --endpoint /v1/chat/completions \
    --model ds32b-pd \
    --tokenizer /models/DeepSeek-R1-Distill-Qwen-32B \
    --dataset-name random \
    --random-input-len $1 --random-output-len $2 \
    --num-prompts 100 --max-concurrency 16 \
    --save-result --result-dir /results/pd-$1-$2
done
```

**必须观察的隐藏成本**：PD 分离把 KV cache 从 prefill 传给 decode，这部分走 `nixl`。跨节点会退化到 TCP，收益骤降。所以：

- 查拓扑命中：`kubectl get pod -o wide` 看 prefill/decode 是否同节点或同 NUMA；
- 如果跨节点，把 `topology-aware scheduling` 打开，或在 ModelServing 里加节点亲和；
- 记录 KV 传输耗时（vLLM 日志里 `Transfer` 相关行），这是 PD 的「手续费」。

**结论范式**：「PD 分离在 4K 输入的摘要场景把 TTFT 从 1.9s 降到 1.2s（-37%），吞吐 +18%；但在 128 输入 / 1K 输出的对话场景，TTFT 反而涨了 8%，因为 KV 传输开销盖过了 prefill 与 decode 解耦的收益。所以我们的路由策略是：长上下文请求走 PD 组，普通对话走共置组。」——**这条结论体现的是判断力，不是装机能力**。

### 2.3 实验 L1-C：AutoScalingPolicy 按队列深度扩缩

**先说前提**：这个实验必须有**至少 2 组可用的 GPU**，否则扩出来的 Pod 一直 Pending，你只能观察「期望副本数算得对不对」。如果只有一组卡，就做降级版：用 1→1 的 policy 验证 `desired_replicas` 计算逻辑 + 用 `maxReplicas=1` 观察它不误扩，这也算一次有效实验，只是不够漂亮。

**Policy（按等待队列长度）**：

```yaml
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: AutoscalingPolicy
metadata:
  name: ds32b-queue-policy
  namespace: ml-serving
spec:
  metrics:
    - metricName: vllm:num_requests_waiting
      targetValue: 8
      tolerancePercent: 30
  behavior:
    scaleUp:
      stablePolicy:
        stabilizationWindow: 30s
        period: 15s
    scaleDown:
      stabilizationWindow: 5m
      period: 1m
```

**Binding**：

```yaml
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: AutoscalingPolicyBinding
metadata:
  name: ds32b-binding
  namespace: ml-serving
spec:
  policyRef:
    name: ds32b-queue-policy
  homogeneousTargets:
    - target:
        targetRef:
          kind: ModelServing
          name: ds32b-scale
      minReplicas: 1
      maxReplicas: 3
```

> `homogeneousTargets` 是列表还是单对象，以 `kubectl explain autoscalingpolicybinding.spec` 为准；不同版本字段层级有差异。

**制造队列的方式**（关键：要让 waiting 真的堆起来）：

```bash
# 以固定 QPS 打，超过服务能力就会出现排队
vllm bench serve --backend openai-chat \
  --base-url http://<router-svc>.ml-serving:80 \
  --endpoint /v1/chat/completions \
  --model ds32b-scale \
  --tokenizer /models/DeepSeek-R1-Distill-Qwen-32B \
  --dataset-name random --random-input-len 2048 --random-output-len 512 \
  --num-prompts 600 \
  --request-rate 8 --max-concurrency 64
```

**三条并行的观察命令**（同时开着）：

```bash
# 1. 副本数变化
kubectl get modelserving ds32b-scale -n ml-serving -w

# 2. 队列深度原始指标
watch -n2 'curl -s http://<pod-ip>:8000/metrics | grep -E "num_requests_(waiting|running)|kv_cache_usage"'

# 3. kthena autoscaler 的决策结果
curl -s http://<kthena-controller-svc>:8080/metrics | grep kthena_autoscaler
#   kthena_autoscaler_desired_replicas
#   kthena_autoscaler_current_replicas
```

**要做三组调参对比**，这才是「实验」而不是「配置」：

| 组 | tolerancePercent | scaleUp window | 期望现象 |
|---|---|---|---|
| A | 50 | 60s | 反应迟钝，P99 抖动大但副本稳定 |
| B | 30 | 30s | 平衡点 |
| C | 10 | 15s | 频繁抖动，副本数锯齿状 |

**必须记录的坑**：扩容出来的新 Pod 要重新下载 65GB 权重，冷启动 3~10 分钟。这意味着**队列深度扩容对突发流量基本无效**——它只适合缓慢上升的负载。真正的突发要靠 `minReplicas` 保底。这个认知比配置本身值钱，而且能直接推出你们的容量规划策略。

### 2.4 实验 L1-D：LoRA 多租户热加载

**这个实验做通了，第二层几乎白送**，因为训练产出的 adapter 可以直接走同一条加载通道。

**原理**：一个 base model 常驻显存，多个 LoRA adapter 动态加载/卸载，共享 base 权重。10 个租户 = 1 份 65GB 权重 + 10 份几十 MB 的 adapter，而不是 10 份 65GB。

**开启运行时更新**（这是前提，不开就只能重启 Pod 换 adapter）：

```yaml
env:
  - name: VLLM_ALLOW_RUNTIME_LORA_UPDATING
    value: "True"
  - name: ENDPOINT
    value: "http://minio.ml-platform:9000"
envFrom:
  - secretRef: { name: minio-s3-cred }
```

**声明 adapter**（改 YAML 即热加载，不重启 Pod）：

```yaml
spec:
  loraAdapters:
    - name: tenant-a
      artifactURL: "pvc://adapters/tenant-a"
    - name: tenant-b
      artifactURL: "pvc://adapters/tenant-b"
```

> `loraAdapters` 的完整子字段（是否还有 `rank`、`revision` 等）以 `kubectl explain modelbooster.spec.loraAdapters` 为准。

**路由**（adapter 名直接作为 OpenAI 请求的 `model` 字段）：

```yaml
apiVersion: networking.serving.volcano.sh/v1alpha1
kind: ModelRoute
metadata:
  name: ds32b-lora
  namespace: ml-serving
spec:
  modelName: "tenant-a"          # 一个 route 一个模型名
  loraAdapters: ["tenant-a"]
  rules:
    - name: to-lora-a
      modelMatch:
        exact: "tenant-a"
      targetModels:
        - modelServerName: "ds32b-lora-server"
```

```bash
curl http://<router-svc>.ml-serving:80/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"tenant-a","messages":[{"role":"user","content":"只输出JSON: 你好"}]}'
```

**核心机制要理解到位**（面试会问）：router 有 `lora-affinity` 插件，会过滤出「当前 Pod 已加载该 adapter」的实例。所以多副本时不会把 `tenant-a` 的请求打到只加载了 `tenant-b` 的 Pod 上。这靠 router 持续拉取引擎指标维护 datastore 实现——**这是动态 LoRA 从「改 YAML」变成「可上线」的关键**。

**要测的三件事**：

1. **显存增量**：加载 1/3/5 个 adapter（rank=16）后的显存增长曲线。预期每个 adapter 约 100~300MB，几乎线性。
2. **TTFT 影响**：单 adapter vs 同时加载 5 个时的 TTFT 差异。LoRA 会增加每层矩阵乘的额外计算，但通常 <5%。
3. **隔离性**：并发请求 tenant-a 和 tenant-b，验证返回内容不串（用各自的 golden set 打分，混淆即失败）。

**限制**（提前知道，别踩）：
- adapter 必须与 base **同架构、同 tokenizer**，词表扩展要用 `--lora-extra-vocab-size`；
- 数量受 `--max-loras`、`--max-lora-rank` 限制，vLLM 默认 `max-loras=1`，多租户必须显式调大；
- rank 不同的 adapter 共存时，`max-lora-rank` 要取最大值，会略微增加显存。

### 2.5 第一层的产出物

做完这 4 个实验，你应该手上有：

- 一份 `bench/` 目录，4×5 组压测 json（量化）+ 3 组 PD 对比 + 3 组扩缩容曲线；
- 一张量化选型表，一张 PD 场景决策表；
- 一套能跑的 `ModelServing + ModelServer + ModelRoute + AutoscalingPolicy` 清单，已经被 Git 管理；
- 一句你自己的选型结论（这块业务到底该用哪个精度、哪种部署形态）。

这就是「面试能讲数字」的全部家当。**没有这四个实验，第二层就只是装软件。**

---

## 3. 第二层：模型迭代闭环

**闭环的定义**：数据 → 训练 → 评测 → 注册 → 灰度 → 观测 → 回滚，全程可复现、可回退、有门禁。

### 3.1 选一个能自造数据的任务

强烈建议选**结构化输出**类任务，因为评价可以程序判定，不依赖人工：

> **任务**：把 K8s / 中间件的原始告警文本，转成固定 schema 的 JSON（`service`、`severity`、`root_cause`、`action`、`needs_human`）。

为什么选这个：
- 数据可以自己造：拿历史告警 + 手工标注，或用 DeepSeek-32B 自己合成再人工抽检；
- 评价客观：JSON 合法性、字段完整率、枚举值合法性、关键实体 F1 都能用脚本算；
- 贴合你的运维背景，讲起来自然；
- base 模型在严格 schema 上表现通常不够稳（会漏字段、编造枚举值），**LoRA 有明确提升空间**——这点很重要，如果 base 已经 98 分，你的微调就没有叙事。

数据量参考：train 800~1500 条，eval 200 条（eval 必须与 train 无重叠，用 `sha256` 去重）。

```json
{"messages":[{"role":"system","content":"你是告警解析器，只输出JSON，不要解释。"},{"role":"user","content":"[FIRING] node-exporter down on node-07 since 10:02"},{"role":"assistant","content":"{\"service\":\"node-exporter\",\"severity\":\"critical\",\"root_cause\":\"exporter_unavailable\",\"action\":\"check_kubelet_and_exporter_pod\",\"needs_human\":true}"}]}
```

### 3.2 离线组件清单

| 组件 | 镜像 | 用途 | 同步难度 |
|---|---|---|---|
| LLaMA-Factory | `hiyouga/llamafactory:0.9.x` | LoRA/QLoRA 训练 | 大（~20GB），跳板机一次性 |
| MLflow | `mlflow:2.x` + PostgreSQL | 追踪 + 注册表 | 小 |
| Argo Workflows | `workflow-controller` / `argocli` / `argoexec` | 流水线 | 小，3 个镜像 |
| eval runner | 自建 `python:3.11-slim` + requests + jsonschema | 评测门禁 | 极小，20 行 Dockerfile |
| 模型制品存储 | NFS PVC（已有）或 MinIO | 权重 / adapter / artifact | 有 NFS 就用 NFS |

**不要引入 ragas / promptfoo 这类框架**。你的评测逻辑就是「调 HTTP + 校验 JSON + 算 F1」，200 行 Python 足够，而且依赖少、离线可控、面试时你能讲清每一行。引入重框架只会让你在离线环境里跟依赖地狱搏斗。

### 3.3 训练（QLoRA）

32B 全参微调需要 8×80G，你没有，所以只能 QLoRA。这也正好解释了为什么不需要 Kubeflow 的 Training Operator。

```yaml
# LLaMA-Factory train 配置要点
model_name_or_path: /models/DeepSeek-R1-Distill-Qwen-32B
stage: sft
do_train: true
finetuning_type: lora
quantization_bit: 4                    # QLoRA
quantization_method: bnb
lora_rank: 16
lora_alpha: 32
lora_dropout: 0.05
lora_target: all                       # 32B 全 target 效果更稳，显存允许就用
dataset: alert2json
template: deepseekr1
cutoff_len: 2048
per_device_train_batch_size: 1
gradient_accumulation_steps: 8
learning_rate: 1.0e-4
num_train_epochs: 2.0
lr_scheduler_type: cosine
warmup_ratio: 0.1
bf16: true
output_dir: /out/alert2json-lora-v1
```

显存估算：4bit 权重 ~19GB + 激活/梯度 ~15GB ≈ 34GB，单卡 48G 可跑，80G 有余量。

**排期规则（重要）**：训练期间必须让推理服务让出 GPU，或者用不同的卡。用 1.1 的 ResourceQuota 强制这一点，否则训练一启动，线上 vLLM 就会因为显存竞争被 OOM 掉。

### 3.4 评测门禁（四层，全部程序判定）

这是整个闭环里最值得打磨的部分。**门禁不严，闭环就是自欺欺人。**

| 层 | 指标 | 判定方式 | 阈值 |
|---|---|---|---|
| L0 格式 | JSON parse 成功率 | `json.loads` | **必须 100%**（硬门禁，一票否决） |
| L1 结构 | 必填字段完整率 | jsonschema | ≥ 99% |
| L2 取值 | 枚举合法性 + 关键实体 F1 | 规则比对 | F1 ≥ baseline |
| L3 语义 | 解决度 1-5 分 | LLM-as-judge | 均值 ≥ baseline |
| L4 回归 | 全部 golden set 的加权分 | 加权公式 | 总分 ≥ baseline + 3% |

**baseline 就是 base 模型（未微调）在同一个 200 条测试集上的分数。** 没有 baseline 的评测是没有意义的——「准确率 85%」本身不是信息，「比 base 高 6.2 个点」才是。

LLM-as-judge 的两个坑：
1. **不要让 32B 评判自己微调后的输出**，有自偏好偏差。用一个独立的小模型（Qwen2.5-7B 或 14B）当评委，单独部署一个 ModelServing。
2. judge 的 prompt 要固定版本并纳入 git，否则换个措辞分数就漂移。

评测脚本结构（够用版）：

```python
# eval/run_eval.py 核心逻辑
results = []
for case in golden_set:
    out = call_router(model=model, messages=case["messages"])
    score = {
        "json_ok": try_parse(out) is not None,
        "schema_ok": validate(out, SCHEMA),
        "enum_ok": check_enums(out),
        "field_f1": f1(out, case["expected"]),
        "judge": llm_judge(out, case["expected"], judge_model="qwen7b"),
    }
    results.append(score)

summary = aggregate(results)
summary["passed"] = (
    summary["json_ok"] == 1.0
    and summary["schema_ok"] >= 0.99
    and summary["field_f1"] >= baseline["field_f1"]
    and summary["judge"] >= baseline["judge"]
)
write_json(summary, "/out/eval_report.json")
```

### 3.5 MLflow 要记录什么（可复现的核心）

| 类别 | 内容 |
|---|---|
| params | 全部训练超参、`base_model_digest`（权重 sha256）、`data_hash`（训练集 sha256）、git commit |
| metrics | eval 五层分数、bench 的 TTFT/TPOT/tok-s、显存峰值 |
| artifacts | `eval_report.json`、训练配置、adapter 的 `sha256`、混淆样本清单 |
| registry | model version + tag：`stage=staging/production`、`eval_score=...`、`approved_by=...` |

**部署 MLflow 时的 NFS 相关配置**：

```bash
mlflow server \
  --backend-store-uri postgresql://mlflow:<pass>@pg.ml-platform:5432/mlflow \
  --default-artifact-root file:///mnt/mlflow \
  --artifacts-destination file:///mnt/mlflow \
  --allowed-hosts mlflow.internal,localhost:5000
```

- 元数据放 PostgreSQL，artifact 放 NFS，两者分离备份。
- `file://` artifact root 在 NFS 上**多客户端并发写有锁风险**。缓解方式是每个训练任务用独立的 run 子目录（MLflow 默认按 `run_id` 分目录）；如果后面出现 artifact 丢失或覆盖，那就是该换 S3 的信号——这也正是方案 B 存在的意义。
- ~~`--allowed-hosts` 必须带 Higress 访问域名，否则 UI 直接 403（见坑 4）。~~
  > ⚠ **勘误（2026-11-13，以实测为准）**：实际部署用的是 MLflow **2.17.2**，
  > 该版本**没有** `--allowed-hosts` 参数（2.18+ 才引入），加了直接
  > `No such option` 退出容器；2.17 默认不校验 Host，**不加即可**。
  > 详见《MLflow-离线部署与模型登记》坑 1 与 `01-部署与模型登记/01-mlflow.yaml` 注释。

**「可复现」的真正含义**：任何人拿到 `run_id`，能查出数据是哪个版本、代码是哪个 commit、adapter 是哪份、评测用的哪个 judge prompt，从而一模一样地重跑出来。这四样缺一样，就不算可复现。

### 3.6 Argo Workflow DAG

```
prepare-data ──> finetune ──> upload-adapter ──> eval ──> gate(suspend) ──> bump-manifest ──> canary-watch
                                    │                                              │
                                    └──> mlflow-log(register) ──────────────────────┘
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: alert2json-
  namespace: ml-platform
spec:
  entrypoint: pipeline
  serviceAccountName: argo-ml          # 需要 RBAC: modelserving/modelroute 的 patch 权限
  templates:
    - name: pipeline
      dag:
        tasks:
          - name: prepare-data
            template: prepare
          - name: finetune
            dependencies: [prepare-data]
            template: train
          - name: upload-adapter
            dependencies: [finetune]
            template: upload
          - name: eval
            dependencies: [upload-adapter]
            template: evaluate
          - name: gate
            dependencies: [eval]
            template: approve
            when: "{{tasks.eval.outputs.parameters.passed}} == true"
          - name: bump-manifest
            dependencies: [gate]
            template: git-bump
          - name: canary-watch
            dependencies: [bump-manifest]
            template: watch
```

四个实现要点：

1. **`gate` 用 suspend 模板做人工审批**（内网没 UI 就 `argo resume <wf>`）。不要让自动门禁直接上线，人工那一步是「有 gate」的证据。
2. **`when` 条件做失败短路**：eval 不通过就不进 git-bump，工作流停在 gate 之前。
3. **NFS 环境下用共享卷传数据，不要用 artifactRepository**。Argo 的 artifactRepository 只支持 S3/GCS/OSS/HDFS/Artifactory，不支持 PVC。做法是给每个 step 挂同一个 RWX PVC，`archive: none`，用固定路径交接：
   ```yaml
   volumeMounts:
     - { name: work, mountPath: /work }
   # 各 step 之间用 /work/runs/{{workflow.name}}/ 下的文件交接 eval_report.json
   ```
   代价是失去 Argo UI 里的 artifact 预览，收益是少一个 MinIO 依赖。若后面接了 MinIO，再换回 S3 artifactRepository。
4. **`bump-manifest` 用 deploy key 提交**：
   ```bash
   git clone git@gitlab.internal:ml/deploy.git /repo
   cd /repo && sed -i "s|adapterURL: .*|adapterURL: pvc://adapters/alert2json-v1|" serving/ds32b-lora.yaml
   git commit -am "chore: promote alert2json-v1 (eval +6.2pt)" && git push
   ```
   ArgoCD 检测到变更后自动 sync，这就是 DevOps 与 MLOps 共用同一条部署通路的证据。

### 3.7 灰度：两种模式，按资源选

**模式 A：按权重灰度（正式 canary，吃双倍显存）**

两个独立 ModelServing（各 1 副本），各自挂 base 和 base+adapter，ModelRoute 用 `weight` 分流：

```yaml
apiVersion: networking.serving.volcano.sh/v1alpha1
kind: ModelRoute
metadata:
  name: ds32b-canary
  namespace: ml-serving
spec:
  modelName: "alert2json"
  rules:
    - name: canary
      targetModels:
        - modelServerName: "ds32b-base-server"      # 旧：base 模型
          weight: 90
        - modelServerName: "ds32b-lora-v1-server"   # 新：base + adapter
          weight: 10
```

- 好处：流量比例精确可控，回滚只需改一个数字，调用方无感知。
- 代价：要两套 GPU。`weight` 是 0-100 的整数，所以最细粒度 1%，做不了千分级灰度。
- 观察 24h → 指标不劣化则 30/70 → 0/100，然后下线旧副本。

**模式 B：按 model 名灰度（省资源，适合先验证）**

同一个 Pod 加载 base + adapter，调用方自己选 `model` 字段：

```json
{"model": "alert2json-v1", "messages": [...]}   // 走 LoRA
{"model": "ds32b-base",    "messages": [...]}   // 走 base
```

- 好处：零额外显存，不用起第二个 Pod。
- 代价：没有自动流量分配，灰度比例靠调用方控制；万一 adapter 有问题，影响面是「所有主动切过去的调用方」。
- 适合：内部工具、A/B 实验、上线前的自测。

**推荐路径**：先用 B 模式验证 adapter 加载正确、输出符合预期（成本最低），确认无误后再用 A 模式做正式 canary（面向真实流量）。

### 3.8 回滚演练（这一步必须做，而且要做两次）

**回滚的三个层次，从快到慢**：

| 手段 | 耗时 | 适用 |
|---|---|---|
| 改 `ModelRoute` weight 为 0 | 秒级 | 流量层回滚，Pod 不动 |
| `git revert` + ArgoCD sync | 30 秒~1 分钟 | 清单层回滚，可审计 |
| 卸载 adapter（改 `loraAdapters`） | 十几秒 | 单租户下线 |

**演练脚本**（这是你面试讲「我真的做了闭环」的硬证据）：

1. 故意训练一个「坏」adapter（比如只训练 20 步，让它输出乱码）；
2. 按正常流程走完 eval → 观察 eval 是否**拦住**了它（如果没拦住，说明门禁有洞，先修门禁）；
3. 强行绕过 gate 上线，权重 10%；
4. 用压测打 10 分钟，观察 L0 格式率掉到多少、告警是否触发；
5. 执行回滚：`kubectl patch modelroute ds32b-canary --type=json -p '[{"op":"replace","path":"/spec/rules/0/targetModels/0/weight","value":100},{"op":"replace","path":"/spec/rules/0/targetModels/1/weight","value":0}]'`；
6. 记录「从发现问题到流量归零」的耗时——**这个秒数就是 MLOps 体系的价值度量**。

---

## 4. 六周排期

| 周 | 内容 | 里程碑 |
|---|---|---|
| W1 | NFS PVC 打通 + 模型入库 + L1-A 量化对比 | 一张量化选型表 |
| W2 | L1-B PD 对比（2×2 矩阵） | PD 场景决策表 |
| W3 | L1-C 扩缩容 + L1-D LoRA 多租户 | 动态 LoRA 跑通，具备第二层前提 |
| W4 | MLflow + Argo 部署 + 数据准备 + base 评测基线 | baseline 分数定下来 |
| W5 | 训练 + 评测门禁 + 注册 + GitOps 提交 | 一次完整流水线跑通 |
| W6 | 灰度 + 回滚演练 + 写报告 | 一份带数字的实践报告 |

如果时间紧，**W1 和 W4 不能省**（量化对比 + 评测基线），W2 可以压缩成半周（只测长输入和短输入两个场景）。

---

## 5. 坑清单

1. **`vllm bench` 默认联网拉数据集和 tokenizer**。必须 `--dataset-name random` + `--tokenizer /本地路径`，否则离线环境直接超时卡住。
2. **prefix caching / chunked prefill 在 vLLM 新版本默认开启**。做对比实验时不显式固定这两个开关，量化前后的数据会被隐性差异污染。
3. **`cacheURI: hostpath://` 只对同节点有效**。扩缩容出来的新 Pod 落到别的节点时，会重新下载 65GB 权重，冷启动从 2 分钟变成 15 分钟。**已有 NFS 就统一走 `pvc://`**——RWX 天然跨节点，这正是 NFS 相对 hostpath 的最大优势。
4. ~~**MLflow 的 `--allowed-hosts`**。经 Higress 访问时如果不把域名加进白名单，UI 直接 403；这个报错很隐蔽，容易以为是 Ingress 问题。~~
   > ⚠ **勘误（2026-11-13）**：MLflow **2.17.2 没有该参数**（2.18+ 才引入），
   > 加了会启动失败；2.17 默认不校验 Host，无需配置。详见《MLflow-离线部署与模型登记》坑 1。
5. **量化的 chat template 不一致**。量化版本仓库里的 `tokenizer_config.json` 有时会被改动，导致 prompt 格式变了，准确率对比失效。
6. **`max-loras` 默认是 1**。多租户不显式调大，第二个 adapter 根本加载不进去，但报错信息可能出现在 runtime 日志而不是 Pod 事件里，容易漏看。
7. **训练和推理抢 GPU**。不隔离就是线上服务被 OOM，必须用 ResourceQuota + 错峰。
8. **ArgoCD 与 Argo Workflows 的 RBAC 别混用**。Workflow 的 SA 需要 `patch modelroute` 权限，ArgoCD 需要 repo 读权限，两者分开授。
9. **判定「评测通过」的阈值不要写在代码里**。放到 ConfigMap 或 workflow 参数里，否则每次改阈值都要重新构建评测镜像。
10. **回滚一定要演练**。没演练过的回滚路径，在真出事的时候 90% 会失败（权限、镜像、Secret 总有一个不对）。
11. **NFS 的两个隐性成本**：默认 mount 参数下 65GB 权重加载可能 10 分钟以上（加 `rsize/wsize=1048576` + `nfsvers=4.1` 可降到 1~2 分钟）；`hard` 挂载在 NFS 服务器无响应时无限重试，Pod 会静默挂起而日志里看不到任何报错。两个都直接影响 L1-C 的冷启动数字，**先量基线再定扩缩容策略**。
    > ⚠ **勘误（2026-11-13）**：本集群 NFS 服务端只支持 NFSv3，`nfsvers=4.1`
    > 与成串优化参数实测挂不上（access denied），最终可用配置为 `vers=3 + nolock`，
    > 详见《MLflow-离线部署与模型登记》坑 2/坑 3。"先量基线"方法论仍然有效。
12. **Argo 的 artifactRepository 不支持 PVC**。NFS 环境下不要指望 `outputs.artifacts` 自动传递 eval 报告，改用 `volumeMounts` 把共享卷挂进每个 step + `archive: none`，用文件路径约定交接。

---

## 6. 写报告时的叙事结构

面试/汇报时按这个顺序讲，每个点都挂数字：

1. **底座**：离线 K8s + Harbor + GitOps 已闭环，交付的是应用镜像。
2. **为什么加推理层**：LLM 服务有 KV cache、prefill/decode 不对称、多租户 LoRA 三个普通微服务没有的问题，HPA 的 CPU 指标对它是失灵的。
3. **量化选型**：4 组精度 × 5 档并发的实测矩阵，结论是「X 精度用一半显卡拿到 1.5 倍吞吐，质量损失 0.5 个点」。
4. **部署形态选型**：PD 分离在长输入场景 -37% TTFT，短输出场景反而劣化，所以做了按请求长度分流的双路由。
5. **弹性**：队列深度扩缩的实际效果受冷启动限制，推出「minReplicas 保底 + 队列扩容应对缓升」的容量策略。
6. **多租户**：一份 65GB 基座 + N 份 adapter，动态加载不重启，lora-affinity 保证不打错副本。
7. **闭环**：LoRA 微调 → 四层评测门禁 → MLflow 注册 → GitOps 灰度 → 秒级回滚，回滚耗时 X 秒。
8. **一句话总结**：DevOps 管「代码到运行」，MLOps 管「数据到模型再到运行」，两条链路共用 Git 和 Harbor 作为唯一事实源。
