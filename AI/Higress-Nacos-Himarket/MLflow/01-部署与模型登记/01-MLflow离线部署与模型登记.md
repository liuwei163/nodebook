# MLflow 离线部署与模型登记经验总结

> 环境：离线 K8s + NFS 共享存储（v3 协议）+ Harbor 私有仓库
> MLflow 版本：2.17.2（镜像已推到 harbor.ai.cnpc/ai-platform-poc/mlflow:v2.17.2）
> 用途：把 NFS 上已有的模型文件登记进 MLflow 注册表，做模型资产管理

---

## 一、MLflow 的两个核心概念（理解一切的前提）

### 1.1 两套存储

MLflow 存两样东西，放在两个地方，容易混淆：

| 存储 | 存什么 | 长什么样 | 对应参数 |
|---|---|---|---|
| **元数据存储** | 文字记录：模型名、版本号、tags、参数、指标 | 数据库（SQLite / PostgreSQL） | `--backend-store-uri` |
| **产物存储（artifact store）** | 实体文件：模型权重、图表、报告 | 文件目录 | `--default-artifact-root` |

类比：**元数据 = 图书馆借阅卡，产物 = 书架上的书**。两者完全独立。

### 1.2 两种 artifact 存储方式（这次踩坑的核心）

artifact（实体文件）有两条存放路径，取决于客户端怎么连 MLflow：

| | 代理模式 | file 模式（直连） |
|---|---|---|
| 连接方式 | 通过 HTTP 连 server | 直接写本地文件 |
| artifact_uri | `mlflow-artifacts:/...` | `file:///...` |
| 客户端需要什么 | 只连 server 就行 | 必须能直接访问存储 |
| 谁能看到 | 所有连 server 的人 | 只有本机 |
| 怎么得到 | `mlflow server` + HTTP 连接 | 代码里 `set_tracking_uri("file:///path")` |

**关键认知**：这两种不是"server 的两种配置"，而是**"用 server"和"不用 server"两种完全不同的用法**。

- 只要你 `mlflow server` + 客户端走 HTTP，artifact_uri 就**永远是** `mlflow-artifacts:/` 形式
- file 模式是放弃 server、直接操作本地目录（单机用）

---

## 二、部署踩过的 4 个坑（按时间顺序）

### 坑 1：`--allowed-hosts` 参数导致容器崩溃

**现象**：容器启动即退出，日志报：

```
Error: No such option: --allowed-hosts
```

**原因**：`--allowed-hosts` 是 MLflow 2.18+ 才有的参数，2.17.2 没有。

**解决**：删掉。而且 2.17 默认不校验 Host 头，不会有 403 Blocked host 问题。

### 坑 2：NFS 协议版本错误

**现象**：

```
mount.nfs: Protocol not supported
```

**原因**：PV 里写了 `nfsvers=4.1`，但服务端只支持 NFSv3。

**排查方法**：在宿主机看现有挂载：

```bash
mount | grep nfs
# 看到 vers=3，说明服务端是 v3
```

**解决**：改成 `vers=3`。

### 坑 3：挂载参数太多导致 access denied

**现象**：

```
mount.nfs: access denied by server while mounting ...
```

**原因**：加了 `rsize/wsize/hard/timeo/retrans/noresvport` 一堆参数，服务端不认。

**解决**：照抄同集群里能正常工作的 PV（dolphinscheduler），只用两个参数：

```yaml
mountOptions:
  - vers=3
  - nolock
```

**经验**：**照着集群里已验证能跑的组件抄配置，比网上查的通用配置靠谱。**

### 坑 4：source 校验失败（最核心的坑）

**现象**：登记模型版本时报：

```
Invalid model version source: '/path/to/model'
To use a local path as a model version source, the run_id request parameter
has to be specified and the local path has to be contained within the
artifact directory of the run specified by the run_id.
```

**原因**：MLflow 2.17 的 Model Registry 强制要求 source 必须来自某个 run 的 artifact 目录，且因为走了代理模式，source 要用 `mlflow-artifacts:/` 前缀。

**踩过的错误 source 写法**（全部被拒）：

| 写法 | 结果 |
|---|---|
| `/mnt/nfs-temp/models/xxx`（纯路径） | 拒绝 |
| `file:///mnt/nfs-temp/models/xxx` | 拒绝 |
| `models:///xxx` | 报"not a proper models:/ URI" |
| `DeepSeek-xxx`（相对路径） | 被拼成 `/DeepSeek-xxx` 后拒绝 |

**正确写法**：

```
mlflow-artifacts:/0/<run_id>/artifacts/<模型名>
```

前提：先建占位 run，再在 run 的 artifact 目录建同名子目录。

---

## 三、完整的登记流程（已验证跑通）

```bash
# 1) 建占位 run（Default 实验 id=0）
curl -X POST http://127.0.0.1:5000/api/2.0/mlflow/runs/create \
  -H 'Content-Type: application/json' \
  -d '{"experiment_id":"0","start_time":1793757141585}'
# 记下 run_id

# 2) 在 run 的 artifact 目录建占位子目录
kubectl -n ml-platform exec deploy/mlflow -- mkdir -p \
  /data/artifacts/0/<run_id>/artifacts/<模型名>

# 3) 建模型条目（已存在报 RESOURCE_ALREADY_EXISTS 属正常）
curl -X POST http://127.0.0.1:5000/api/2.0/mlflow/registered-models/create \
  -H 'Content-Type: application/json' -d '{"name":"<模型名>"}'

# 4) 注册版本（source 用 mlflow-artifacts:/ 前缀）
curl -X POST http://127.0.0.1:5000/api/2.0/mlflow/model-versions/create \
  -H 'Content-Type: application/json' -d '{
    "name": "<模型名>",
    "source": "mlflow-artifacts:/0/<run_id>/artifacts/<模型名>",
    "run_id": "<run_id>",
    "description": "BF16 基座",
    "tags": [{"key":"storage_path","value":"/mnt/nfs-temp/models/<模型名>"}]
  }'

# 5) 标记生产版本（可选）
curl -X POST http://127.0.0.1:5000/api/2.0/mlflow/model-versions/transition-stage \
  -H 'Content-Type: application/json' \
  -d '{"name":"<模型名>","version":"1","stage":"Production"}'
```

已封装成脚本：`01-部署与模型登记/01-register-model.sh`，一条命令搞定。

---

## 四、关键认知总结

### 4.1 MLflow 的定位边界

**MLflow 的 Model Registry 是为"训练即注册"的闭环设计的**：

```
训练代码 mlflow.log_model() → 自动成为 run 的 artifact → 一键注册成版本
```

它对"登记预先存在别处的模型文件"不友好——没有顺畅的入口，UI 里找不到"填路径注册"的按钮，API 的 source 校验也强制要求模型来自某个 run。

**结论**：用 MLflow 管理"已有模型台账"是逆着设计硬走，能用但不优雅。等有真正的训练流程时，用 `mlflow.log_model()` 会自动顺很多。

### 4.2 正确的心智模型

- **元数据 ≠ 产物**：模型名、版本号在数据库，权重文件在 NFS
- **代理模式 ≠ file 模式**：前者走 server（跨机器），后者走本地（单机）
- **source 字段记的是"代理协议路径"，不是真实文件路径**：真实 NFS 路径要靠 tag 记录
- **登记 ≠ 拷贝**：MLflow 只记路径和元数据，不搬运 65GB 的权重文件

### 4.3 运维教训

1. **照着集群里已验证能跑的组件抄配置**（NFS 参数、挂载方式），比查通用文档靠谱
2. **删 PV 要小心**：MLflow 的元数据（SQLite）和产物（artifacts）都在同一个 PV 里，删 PV 会连数据一起丢
3. **版本差异是真实的坑**：参数名（`--allowed-hosts`）、命令名（`mlflow models register` 不存在）在不同版本间会变，遇到报错先确认版本
4. **生产环境的正确形态**：SQLite 换 PostgreSQL（支持多副本），元数据和产物分开存储，定期备份

---

## 五、相关文件索引

| 文件 | 内容 |
|---|---|
| `01-部署与模型登记/01-mlflow.yaml` | 部署清单（含 PV/PVC/Deployment/Service + 登记流程说明） |
| `01-部署与模型登记/01-register-model.sh` | 单模型登记脚本 |
| 本文档 | 踩坑记录 + 概念解释 |

---

## 六、勘误与修复（2026-11-06）：产物实际写入位置由 --artifacts-destination 决定

### 6.1 发现

本地训练（iris-150x6）成功后，在节点上查 NFS（`/mnt/nfs-temp/mlflow/artifacts`），
只看到 `0/` 下的两个旧占位 run 目录，**没有新训练的产物**。

### 6.2 根因

之前对 `mlflow server` 的理解有一处关键错误：

| 参数 | 之前的理解 | 实际行为（MLflow 2.x） |
|---|---|---|
| `--serve-artifacts` | 以为需要显式加才开启 | **`mlflow server` 默认开启**（不加也是开着的） |
| `--default-artifact-root` | 以为它决定"产物实际写到哪" | 代理模式下**被忽略**（只在未开代理时生效） |
| `--artifacts-destination` | 不知道这个参数 | **实际写入位置的基准**，默认 `./mlartifacts` |

于是产物被写到了 `./mlartifacts`（相对 server 进程工作目录 = **容器本地盘**）：
- UI 里一切正常（代理模式读的正是这个位置）
- NFS 上看不到（落错盘了）
- **Pod 一重启，容器本地文件全部丢失**（今天的 v1 模型文件就处于这个状态）

元数据（mlflow.db）不受影响——它显式指定了绝对路径 `/data/mlflow.db`，一直在 NFS 上。

### 6.3 修复步骤（已更新 01-部署与模型登记/01-mlflow.yaml）

```bash
# ① 确认产物现在在容器哪里（找 mlartifacts 的实际位置）
kubectl -n ml-platform exec deploy/mlflow -- sh -c \
  "find / -maxdepth 3 -type d -name mlartifacts 2>/dev/null"
# 假设找到 /mlflow/mlartifacts（即容器 WORKDIR 下）

# ② 【必须先做】把已有产物迁到 NFS（再改配置重启就晚了）
kubectl -n ml-platform exec deploy/mlflow -- sh -c \
  "cp -a /mlflow/mlartifacts/. /data/artifacts/ && ls /data/artifacts"
# 应看到 0/、1/（real-model-practice 的实验 id）、2/（ops-practice）等目录

# ③ 应用修正后的 01-部署与模型登记/01-mlflow.yaml（args 里 default-artifact-root
#    换成了 --artifacts-destination=/data/artifacts）
kubectl -n ml-platform apply -f 01-部署与模型登记/01-mlflow.yaml

# ④ Recreate 策略自动重启；就绪后在节点上复查
ls /mnt/nfs-temp/mlflow/artifacts        # 能看到新实验目录了

# ⑤ UI 里点开旧 run 的 Artifacts 确认仍可浏览；本地再跑一次训练，节点上确认落盘
```

### 6.4 教训

1. **"没配 = 默认值"也是配置**：`--serve-artifacts` 不加≠关闭，反而默认开启，直接改变了文件去向
2. **验证落盘要看最终存储，不能只看 UI 正常**：代理模式下 UI 正常≠文件在你想的盘上
3. 有本地盘数据风险的变更，**先迁移再重启**（Recreate 策略杀掉旧容器即丢失）
