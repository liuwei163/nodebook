# HiMarket 跨集群接入模型集群模型 · 全流程配置手册

> 适用版本：HiMarket v0.8.2 / Higress 2.x / vLLM-Ascend 0.22.1
> 场景：HiMarket 部署在 A 集群（管理集群），模型推理服务在 B 集群（算力集群），两集群网络互通但无跨集群 Service 发现。
> 本文所有命令、字段、取值均来自 2026-11-09 Qwen3-32B 实际打通的过程，可直接照抄。

---

## 目录

- [0. 先读这一页](#0-先读这一页)
- [1. 架构与三个"名字"](#1-架构与三个名字)
- [2. 前置检查与取值清单](#2-前置检查与取值清单)
- [3. 阶段一：模型集群侧准备](#3-阶段一模型集群侧准备)
- [4. 阶段二：HiMarket 集群配置服务来源](#4-阶段二himarket-集群配置服务来源)
- [5. 阶段三：配置 AI 服务提供者](#5-阶段三配置-ai-服务提供者)
- [6. 阶段四：配置 AI 路由](#6-阶段四配置-ai-路由)
- [7. 阶段五：打通 HiChat 出网（DNS 与端口）](#7-阶段五打通-hichat-出网dns-与端口)
- [8. 阶段六：产品化与发布](#8-阶段六产品化与发布)
- [9. 阶段七：全链验收](#9-阶段七全链验收)
- [10. 故障速查表](#10-故障速查表)　（10.2 专讲「话说一半就断 / `<think>` 泄漏」的三层判定）
- [11. 变更与回滚](#11-变更与回滚)
- [附录 A：本次实测参数](#附录-a本次实测参数)
- [附录 B：命令速查](#附录-b命令速查)

---

## 0. 先读这一页

### 0.1 这条链路为什么容易卡住

跨集群接模型，本质是**在两个互不相识的网关之间建立约定**。两个网关各自只认自己集群里的规则，能对上的只有一个东西：**HTTP 请求里的 Host 头**。

所以整条链路的成败，最后都收敛到一个问题：

> 发给 B 集群网关的 Host，在 B 集群里有没有对应的路由？

其他所有配置（服务来源、AI 提供者、AI 路由、hostAliases）都是为了让这个 Host 能被正确产生、正确送达。

### 0.2 五个常见误区

| 误区 | 事实 |
|---|---|
| 「两边域名必须一样」 | **不必**。下游入口域名和上游 Host 是两个独立字段，可以不同。硬约束只有"B 集群必须有上游 Host 的路由" |
| 「发到门户就可见了」 | 还有订阅关系、以及**门户是否匹配**两道关 |
| 「`openaiCustomUrl` 填 `/v1` 就行」 | ai-proxy 是**整体替换路径**，必须填完整端点 `/v1/chat/completions` |
| 「毫秒级 404 是模型的问题」 | 毫秒级 = 根本没转发出去，是**本地路由没匹配** |
| 「模型名和域名可以混用」 | 域名 `qwen3.32b`（点）与模型名 `qwen3-32b`（横线）是两回事，混用必 404 |

### 0.3 本文的验证节奏

每个阶段末尾都有「**本阶段验收**」，不通过就不要进入下一阶段。跨集群问题最大的成本是"两个环节同时怀疑"，逐段验收是唯一能压住复杂度的方法。

---

## 1. 架构与三个"名字"

### 1.1 完整链路

```
┌─────────────┐
│  浏览器/HiChat│
└──────┬──────┘
       │ ① http://qwen3.32b.example.internal/v1/chat/completions
       │    （域名解析靠 Pod 内 hostAliases → HiMarket 网关 ClusterIP）
       ▼
┌──────────────────────────────────────┐
│  A 集群 · HiMarket 侧 Higress 网关     │
│  - 按 Host 匹配 AI 路由                │
│  - ai-proxy 插件改写路径 + 改写 Host   │
│  - 转发到静态服务（B 集群网关 IP:端口）│
└──────┬───────────────────────────────┘
       │ ② Host: qwen3.32b.example.internal（由"自定义主机名"决定）
       │    Path: /v1/chat/completions（由"服务路径"决定）
       ▼
┌──────────────────────────────────────┐
│  B 集群 · 模型侧 Higress 网关          │
│  - 按 Host 匹配 Ingress               │
│  - 转发到 vLLM Service                │
└──────┬───────────────────────────────┘
       │ ③ Host: qwen3.32b.example.internal
       ▼
┌──────────────────────────────────────┐
│  B 集群 · vllm-qwen3-32b Pod:8000     │
│  - --served-model-name qwen3-32b      │
│  - --enable-auto-tool-choice          │
└──────────────────────────────────────┘
```

### 1.2 三个"名字"必须分清

这是整个配置最容易混的地方，先记住这张表，后面每一步都在往里填：

| # | 名字 | 出现在哪 | 作用 | 本次取值 |
|---|---|---|---|---|
| ① | **下游域名** | AI 路由的「域名」 | 客户端用什么名字进来 | `qwen3.32b.example.internal` |
| ② | **上游 Host** | AI 提供者的「自定义主机名」 | 转发给 B 集群时带什么 Host | `qwen3.32b.example.internal` |
| ③ | **模型名** | 请求体的 `model` 字段 | vLLM 认哪个模型 | `qwen3-32b` |

**①②可以不同，但③必须等于 vLLM 的 `--served-model-name`。**

上次排障时 `openaiCustomUrl` 填的是 `model-gw.example.internal`（②），路由域名是 `ds32b-local.model.example.internal`（①），两者不一致——这不是错误，只要 B 集群认 `model-gw.example.internal` 就能通。真正卡住的是 A 集群里另一条路由抢了同一个 Host，请求根本没走出去。

### 1.3 为什么不用 Kthena 的 ModelServing

当前 B 集群的 vLLM 是**裸 Deployment + Service**，没有走 Kthena 的 `ModelServing`。原因值得记录：

- 走 `ModelServing` 方式时，官方要求**手动创建三个对象**：`ModelServing`（起 Pod）、`ModelServer`（网络层）、`ModelRoute`（路由）。
- `ModelServer` 的核心字段是 `pdGroup`（prefill/decode 配对）和 `kvConnector`（KV cache 传输），语义强依赖 **PD 分离**拓扑。
- 而共置单角色（`role: server`）的拓扑没有 prefill/decode 之分，`pdGroup` 无可配对，与 router 的调度逻辑冲突。

**结论**：要么 PD 分离 + 三个对象 + 走 kthena-router，要么共置单角色 + Higress 直连 Pod。二者不要混搭。

---

## 2. 前置检查与取值清单

### 2.1 网络前提

| 检查项 | 命令 | 期望 |
|---|---|---|
| A 集群能访问 B 集群网关 | 在 A 集群任一 Pod 内 `curl -m 5 http://<B网关IP>:<端口>` | 拒绝连接以外的任何响应都算通 |
| B 集群网关已对外暴露 | `kubectl -n higress-system get svc \| grep gateway` | `type` 为 NodePort / LoadBalancer |
| 防火墙 | 运维确认 | 放通对应端口 |

**关键**：跨集群**不能**用 ClusterIP（如 `10.233.x.x`）或 Service 名，只能用**节点 IP + NodePort**、LoadBalancer IP、或 VIP。

### 2.2 权限前提

- A 集群：HiMarket 管理员权限（能建产品、发布、管理 Consumer）
- A 集群：Higress 控制台管理员（能改服务来源、AI 提供者、AI 路由）
- B 集群：能建 Ingress、能改 Deployment

### 2.3 取值清单（先填完再动手）

```bash
# ===== B 集群（模型集群）=====
# 1) 模型 Service 名与端口
kubectl -n kthena-system get svc | grep -i vllm

# 2) 模型侧网关对外地址
kubectl -n higress-system get svc | grep -i higress-gateway
kubectl -n higress-system get pods -o wide | grep higress-gateway

# 3) IngressClass 名字
kubectl get ingressclass

# ===== A 集群（HiMarket 集群）=====
# 4) HiMarket 侧网关 ClusterIP（hostAliases 要用）
kubectl -n himarket get svc higress-gateway -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl -n himarket get svc higress-gateway -o wide        # 确认有 80/TCP

# 5) 现有服务来源（McpBridge 实际所在命名空间）
kubectl get mcpbridge -A

# 6) 现有 AI 路由与域名占用
kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.rules[*].host}{"\n"}{end}'
```

填完这张表再往下：

| 变量 | 值 |
|---|---|
| B 集群模型 Service | `kthena-system/vllm-qwen3-32b:8000` |
| B 集群网关地址 | `<MODEL_GW_IP>:30081` |
| A 集群网关 ClusterIP | `<HIMARKET_GW_IP>` |
| 计划使用的域名 | `qwen3.32b.example.internal` |
| vLLM 的 served-model-name | `qwen3-32b` |

---

## 3. 阶段一：模型集群侧准备

**目标**：B 集群内，一个域名 → 一个 vLLM Service，且工具调用可用。

### 3.1 确认 vLLM 正常运行

```bash
kubectl -n kthena-system get pods -l app=vllm-qwen3-32b -o wide
kubectl -n kthena-system logs -l app=vllm-qwen3-32b --tail=30 | grep -Ei "startup complete|error"
```

看到 `Application startup complete` 才算加载完成。32B 从 NFS 加载 + 昇腾算子编译，**5–8 分钟**属正常，这期间探针失败不要急着改配置。

### 3.2 启动参数（逐条说明）

```yaml
args:
  - >-
    source /usr/local/Ascend/ascend-toolkit/set_env.sh &&
    python3 -m vllm.entrypoints.openai.api_server
    --host 0.0.0.0
    --port 8000
    --model /models/Qwen3-32B
    --served-model-name qwen3-32b
    --tensor-parallel-size 8
    --gpu-memory-utilization 0.92
    --max-model-len 32768
    --max-num-batched-tokens 16384
    --no-enable-log-requests
    --disable-log-stats
    --trust-remote-code
    --enable-auto-tool-choice
    --tool-call-parser hermes
    --reasoning-parser qwen3
```

| 参数 | 作用 | 设错的后果 |
|---|---|---|
| `--served-model-name qwen3-32b` | 对外暴露的模型 ID | 与请求体 `model` 不一致 → `404 model not found` |
| `--tensor-parallel-size 8` | 张量并行数 | 必须等于 `huawei.com/Ascend910` 数量，否则起不来 |
| `--gpu-memory-utilization 0.92` | HBM 预分配上限 | 过高 OOM，过低放不下 KV cache |
| `--max-model-len 32768` | 单请求最大上下文 | 太小会在多轮工具调用中被截断 |
| `--no-enable-log-requests` | 不打印 prompt 明细 | 生产必须关，否则日志爆盘且泄露用户输入 |
| `--enable-auto-tool-choice` | 允许模型自主决定调工具 | **不开则带 tools 的请求在入口直接 400** |
| `--tool-call-parser hermes` | 解析 `<tool_call>{json}</tool_call>` | 配错则解析不出 `tool_calls` |
| `--reasoning-parser qwen3` | `<think>` 段拆到 reasoning 字段 | 不配则思考链混进 content，污染多轮上下文 |

> **踩过的坑**：Qwen3 系列务必用 `--reasoning-parser qwen3`。抄成 `deepseek_r1` 会导致回复内容全空——文本全落到思考段里。
> 另：不要同时写 `--enable-reasoning`，0.9 之后由 `--reasoning-parser` 承担。

**这个参数是「搬运工」，不是「开关」**，两件事必须分清：

| 事项 | 由谁决定 |
|---|---|
| 模型**要不要**先思考（输出 `<think>` 标签） | chat template 的 `enable_thinking` |
| 想完之后**怎么拆字段**（reasoning / content） | `--reasoning-parser qwen3` |

它只在文本生成完之后工作：识别成对的 `<think>`…`</think>`，把中间切进 `reasoning_content`，剩下塞 `content`。
**它不改模型行为**——加不加这个参数，模型该吐的标签一个字不少。

**静默失效的唯一条件：标签不成对。** 只看到 `<think>`、没看到 `</think>` 时，parser 无法判定边界，只能保守地整段当正文返回，
**不报错、不打日志**。于是表现成「第一轮思考正常折叠，第二轮正文里裸奔一个 `<think>`」。
根因不是 parser 配错，是**生成被 max_tokens 截断了**——见 10.2。

### 3.3 模型侧 Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vllm-qwen3-32b
  namespace: kthena-system
spec:
  selector:
    app: vllm-qwen3-32b
  ports:
    - name: http
      port: 8000
      targetPort: 8000
  type: ClusterIP
```

```bash
kubectl apply -f vllm-qwen3-32b-deploy.yaml
kubectl -n kthena-system get svc vllm-qwen3-32b
```

### 3.4 模型侧 Higress 路由

**先查现有 Ingress，确认域名没被占用：**

```bash
kubectl get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.rules[*].host,SVC:.spec.rules[*].http.paths[*].backend.service.name,PORT:.spec.rules[*].http.paths[*].backend.service.port.number'
```

同 host 挂两条 Ingress → 随机命中一条 → 极难排查。**域名必须唯一。**

创建：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qwen3-32b
  namespace: kthena-system
spec:
  ingressClassName: higress            # 按 kubectl get ingressclass 的实际值
  rules:
    - host: qwen3.32b.example.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vllm-qwen3-32b
                port:
                  number: 8000
```

```bash
kubectl apply -f qwen3-ingress.yaml
kubectl -n kthena-system get ingress qwen3-32b
```

> 优先用标准写法，它最简单。部分定制版 Higress 禁止 Ingress 直连 Service，此时改走下面这条备选路径。

**备选：McpBridge `type: dns` + `higress.io/destination` 注解**

```yaml
# 追加到模型集群现有 McpBridge 的 spec.registries 里
- name: vllm-qwen3
  type: dns
  domain: vllm-qwen3-32b.kthena-system.svc.cluster.local
  port: 8000
```

Ingress 侧把 backend 换成注解指向它：

```yaml
metadata:
  annotations:
    higress.io/destination: vllm-qwen3.dns:8000
```

差别只有一处：标准写法由 K8s Service 直接解析后端，dns 类型由 Higress 自己按域名解析，绕开了「Ingress 直连 Service」这个动作。两种写法对下游（HiMarket 侧）完全等价，切换不影响后续阶段。

### 3.5 本阶段验收 ★

**必须显式带 Host**，因为这就是 A 集群将来送进来的东西：

```bash
curl -s -m 30 -o /dev/null -w '%{http_code} %{time_total}s\n' \
  http://<MODEL_GW_IP>:30081/v1/chat/completions \
  -H 'Host: qwen3.32b.example.internal' \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-32b","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

期望 `200 2.x s`。

### 3.6 本阶段常见错误

| 现象 | 原因 | 处理 |
|---|---|---|
| 毫秒级 404 | Host 没匹配上 | 检查 `spec.rules[].host` 与命令里的 Host 是否逐字一致 |
| `503` | Ingress backend 的 Service 名/端口错 | 对照 `kubectl get svc` |
| `404 model not found` | 请求体 `model` 与 `--served-model-name` 不一致 | 改成一致 |
| 连接被拒 | 网关 NodePort 不通 | 查 `svc higress-gateway` 的 `type` 与端口 |

---

## 4. 阶段二：HiMarket 集群配置服务来源

**目标**：让 A 集群的 Higress 认识 B 集群的网关地址。

### 4.1 控制台操作

HiMarket 控制台 → **服务来源** → **创建服务来源**

| 字段 | 填什么 | 说明 |
|---|---|---|
| 类型 | **固定地址** | 跨集群必须用固定地址（static），不能用 Kubernetes 类型 |
| 名称 | `qwen3-32b` | 建议与模型同名，便于识别 |
| 服务端口 | `80` | A 集群侧访问时使用的端口 |
| 服务地址 | `<MODEL_GW_IP>:30081` | **B 集群网关的节点 IP + NodePort** |
| 服务协议 | `HTTP` | |

**关键点**：`服务地址` 必须是跨集群可达的地址。写成 ClusterIP（`10.233.x.x`）或 Service 名一定失败。

### 4.2 校验

```bash
kubectl get mcpbridge -A
kubectl -n <上一步输出的命名空间> get mcpbridge -o yaml | grep -A8 "qwen3-32b"
```

期望看到：

```yaml
registries:
  - name: qwen3-32b
    type: static
    domain: <MODEL_GW_IP>:30081
```

### 4.3 本阶段验收 ★

从 **A 集群的网关 Pod** 里直接打 B 集群网关（绕开所有路由和插件，只测网络 + Host）：

```bash
GW=$(kubectl -n himarket get pods -o name | grep higress-gateway | head -1 | cut -d/ -f2)
kubectl -n himarket exec $GW -- curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -m 10 \
  http://<MODEL_GW_IP>:30081/v1/chat/completions \
  -H 'Host: qwen3.32b.example.internal' \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-32b","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

| 结果 | 含义 | 下一步 |
|---|---|---|
| `200` | 网络与 Host 都通 | 进入阶段三 |
| 超时 / 拒绝 | 网络、端口或防火墙 | 先解决这层，别改配置 |
| `404` 且毫秒级 | Host 不对 | 回阶段 3.4 核对 host |

**这一步是整个流程的分水岭。** 它过了，后面只是"让 HiMarket 按正确方式产生这个请求"；它不过，后面所有配置都无效。

---

## 5. 阶段三：配置 AI 服务提供者

**目标**：告诉 ai-proxy 插件"用哪个上游、什么路径、什么 Host"。

### 5.1 控制台操作

**AI 网关管理 → AI 服务提供者管理 → 创建 AI 服务提供者**

| 字段 | 填什么 | 说明 |
|---|---|---|
| OpenAI 服务类型 | **自定义服务** | |
| 自定义 OpenAI 服务配置方式 | **选择服务** | |
| 自定义 OpenAI 服务 | `qwen3-32b.static:80` | 格式 `<服务来源名>.static:<服务端口>` |
| **自定义 OpenAI 服务路径** | `/v1/chat/completions` | **必须完整端点** |
| **自定义 OpenAI 服务主机名** | `qwen3.32b.example.internal` | 转发给 B 集群时的 Host |
| 首包超时（毫秒） | 留空 或 `60000` | 留空=不开启；长 prompt 场景建议 60000 |

### 5.2 为什么路径必须完整

ai-proxy 的 `isDirectCustomPath` 判定逻辑是：**路径以 `/completions` 结尾时，整体替换请求路径**，而不是拼接。

```
原始请求：  POST /v1/chat/completions
配置为 /v1：→ 请求变成 /v1  → B 集群 404
配置为 /v1/chat/completions → 请求保持 /v1/chat/completions → 正常
```

这就是为什么填 `http://xxx/v1` 一定失败，而填完整端点能通。

### 5.3 主机名的两种合法写法

| 写法 | 效果 | 适用 |
|---|---|---|
| 填域名 | Host 被改写为该域名 | **推荐**，B 集群按域名匹配，稳定 |
| 留空 | Host 为上游服务名（`qwen3-32b.static`） | B 集群不认，几乎必然 404 |

### 5.4 校验

```bash
kubectl -n himarket get wasmplugin | grep -i proxy
kubectl -n himarket get wasmplugin <生成的插件名> -o yaml | grep -E "openaiCustomUrl|modelMapping|name:"
```

期望 `openaiCustomUrl` 包含完整路径。

### 5.5 本阶段验收 ★

从 **himarket-server Pod** 里打 AI 路由域名（这一步同时验证了路由 + 插件 + 上游）：

```bash
kubectl -n himarket exec deploy/himarket-server -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -m 30 \
  http://qwen3.32b.example.internal/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-32b","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

> 此时还没有配 AI 路由，这一步会失败。**正确顺序是先做阶段四再回来验收**，这里列出来是为了说明最终判据。

---

## 6. 阶段四：配置 AI 路由

**目标**：把域名和 AI 提供者绑定，形成对外入口。

### 6.1 控制台操作

**AI 网关管理 → AI 路由管理 → 创建 AI 路由**

| 字段 | 填什么 | 说明 |
|---|---|---|
| 名称 | `qwen3-32b` | |
| **域名** | `qwen3.32b.example.internal` | 必须已存在于「域名管理」；**全集群唯一** |
| 路径匹配规则 | 前缀匹配 `/` | |
| 服务 | `qwen3-32b` | 上一步创建的 AI 提供者 |
| 请求授权 | 按需 | 内部使用可先不开启认证 |

### 6.2 域名唯一性（最坑的一条）

同一域名挂两条 AI 路由时，Higress 只认其中一条，另一条上的所有注解（包括 `upstream-vhost`）**完全无效**。表现是 **3~6 毫秒的 404**。

**判断方法**：查网关日志里的 `route_name`。

```bash
for p in $(kubectl -n himarket get pods -o name | grep higress-gateway); do
  kubectl -n himarket logs $p --since=5m | grep -i "chat/completions" | tail -3
done
```

命中的 `route_name` 不是你以为的那条 → **换域名**，不要去调注解。

> 这条是实测踩出来的：当时 `ai-route-coding.internal` 抢了同一个 host，导致怎么改 `upstream-vhost` 都 404。换域名后立刻通。

### 6.3 生成的对象

控制台会在后台自动创建两个对象，**不要手改**（会被 reconcile 覆盖）：

```bash
kubectl -n himarket get ingress | grep ai-route
kubectl -n himarket get wasmplugin | grep ai-proxy
```

改需求请回控制台改，改完看是否生效。

### 6.4 本阶段验收 ★

```bash
# ① 对象已生成
kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.rules[*].host}{"\n"}{end}' | grep -i qwen3

# ② 从 himarket-server Pod 出请求
kubectl -n himarket exec deploy/himarket-server -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -m 30 \
  http://qwen3.32b.example.internal/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-32b","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

若 ② 报 `Could not resolve host`，属正常——DNS 还没配，进入阶段五。

---

## 7. 阶段五：打通 HiChat 出网（DNS 与端口）

**目标**：让 `himarket-server` Pod 能解析并连上 A 集群自己的网关。

### 7.1 为什么需要这一步

HiChat 用的是 HiMarket 源码 `AbstractLlmService.buildUri()`：

```
优先取 route.getDomains()  → 得到 http://qwen3.32b.example.internal
否则回退 gatewayUris
```

也就是说 **HiChat 直接拿路由域名去连，不经过任何 DNS 兜底**。Pod 解析不了这个域名，就只能在 TCP 层失败。

失败时的错误信息很隐晦：

```
HTTP transport error during streaming: SSE/NDJSON stream failed: null
```

`null` 表示连接没建立（异常对象为空），对应 Java 侧的 `ConnectException: null` 或 `UnknownHostException`。

### 7.2 确认问题

```bash
kubectl -n himarket exec deploy/himarket-server -- getent hosts qwen3.32b.example.internal || echo "NO_DNS"
```

- 输出 IP → 解析正常，跳到 7.4
- `NO_DNS` 且退出码 2 → 名字未找到（`getent` 的退出码 2 就是"一个或多个名字无法解析"）

### 7.3 加 hostAliases

**⚠️ 先读现有值**，`--type merge` 会整段替换数组，不带上旧条目会丢：

```bash
kubectl -n himarket get deploy himarket-server -o jsonpath='{.spec.template.spec.hostAliases}{"\n"}'
```

写入（按实际情况增删 hostnames）：

```bash
kubectl -n himarket patch deploy himarket-server --type merge -p '{
  "spec":{"template":{"spec":{"hostAliases":[
    {"ip":"<HIMARKET_GW_IP>","hostnames":["qwen3.32b.example.internal"]}
  ]}}}
}'

kubectl -n himarket rollout status deploy/himarket-server
```

**逐字核对域名**。`qwen3.32b.example.internal`（点号）与 `qwen3-32b.example.internal`（横线）是两个不同的字符串，抄错一个字符就等于没配。

```bash
# 以控制台/Ingress 里的实际值为准
kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' | grep -i qwen3
```

### 7.4 端口必须是 80

HiChat 拼 URL 时，schema 为 http 且域名不带端口 → **默认连 80**。A 集群网关 Service 端口不是 80 就 `Connection refused`。

```bash
kubectl -n himarket get svc higress-gateway -o wide
# 期望 PORTS 含 80/TCP
```

不是 80 就用带 `test` 保护的 patch（避免改错位置）：

```bash
kubectl -n himarket patch svc higress-gateway --type json -p '[
  {"op":"test","path":"/spec/ports/0/port","value":30080},
  {"op":"replace","path":"/spec/ports/0/port","value":80}
]'
```

> 这一段是实测踩出来的：Service 原本是 `30080`，Pod 内 `getent` 已经返回 IP 了，但 `/dev/tcp/<ip>/80` 报 `Connection refused`，症状极易被误判为 DNS 问题。

### 7.5 本阶段验收 ★★

三步全过，链路才算真的通：

```bash
# ① 解析
kubectl -n himarket exec deploy/himarket-server -- getent hosts qwen3.32b.example.internal
# 期望：<HIMARKET_GW_IP>    qwen3.32b.example.internal

# ② 非流式
kubectl -n himarket exec deploy/himarket-server -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -m 30 \
  http://qwen3.32b.example.internal/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-32b","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
# 期望：200 0.4s 左右

# ③ 流式（HiChat 实际走 SSE）
kubectl -n himarket exec deploy/himarket-server -- \
  curl -sN -m 30 http://qwen3.32b.example.internal/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-32b","stream":true,"messages":[{"role":"user","content":"hi"}],"max_tokens":16}' | head -5
# 期望：若干 data: {...} 帧
```

实测结果参考：

```
<HIMARKET_GW_IP>    qwen3.32b.example.internal
200 0.394360s
data: {"id":"chatcmpl-...","choices":[{"delta":{"role":"assistant","content":""}}]}
data: {"id":"chatcmpl-...","choices":[{"delta":{"reasoning":"\n"}}]}
```

> **关于 `reasoning` 字段**：Qwen3 默认开思考，内容先落到 `delta.reasoning`。实测 HiChat 能正常渲染（回复上方有可折叠的「思考过程」），**不需要**额外关思考。只有在意首字延迟时才在 vLLM 加 `--default-chat-template-kwargs '{"enable_thinking": false}'`，或在请求体加 `"chat_template_kwargs":{"enable_thinking":false}`。

### 7.6 本阶段常见错误

| 现象 | 原因 | 处理 |
|---|---|---|
| `SSE/NDJSON stream failed: null` | Pod 内 DNS 失败 | 7.3 hostAliases |
| `Connection refused` | 网关不是 80 端口 | 7.4 |
| `Chat stream error: 404` | 请求到了网关但路由没匹配 | 查 `route_name` |
| 改了 hostAliases 仍失败 | Pod 未滚动完成 | `rollout status` 等待 |
| 一段时间后又失败 | 重装/重部署丢了 hostAliases | 见 11 节回滚说明 |

---

## 8. 阶段六：产品化与发布

**目标**：把 AI 路由包装成产品，让开发者能订阅、能用。

这一步是纯运营动作，与链路无关，但**坑最多的是"发布了却看不见"**。

### 8.1 建 Model API 产品

控制台 → **API 产品 → 创建** → 类型选 **Model API**

| 字段 | 说明 |
|---|---|
| 产品名称 | 如 `Qwen3-32B-Agent` |
| 适用场景 | 文本生成 |
| 协议 | OpenAI / V1 |

### 8.2 Link API（关联 API）

产品详情 → **关联 API** → 选择刚建的 AI 路由 `qwen3-32b`

关联成功后页面会显示：

```
名称：qwen3-32b        类型：Model API
来源：Higress 网关      网关 ID：higress-xxxx
协议：OpenAI/V1
路由配置：http://qwen3.32b.example.internal/
```

**核对点**：这里的域名必须与你配的 AI 路由域名一致。若显示的不是你预期的域名，说明关联到了别的路由。

### 8.3 Usage Guide（使用指南）

产品详情 → **使用指南**，写清三件事：

1. **能力标签**：支持 tool calling / MCP / Skill；上下文 32K
2. **调用示例**：给出 curl，含 `model` 字段的确切值
3. **注意事项**：如"默认开启思考链，可在请求中传 `enable_thinking:false` 关闭"

这一步决定了开发者会不会用错模型。

### 8.4 发布（最容易卡住的一步）

产品详情 → **门户** 页签 → 勾选目标门户 → 保存。

**关键认知：发布 ≠ 可见，中间还有两道关。**

| 关卡 | 说明 | 不满足的表现 |
|---|---|---|
| ① 门户匹配 | 产品上架的门户，必须和当前访问入口所属门户一致 | 换到对的域名才看得见 |
| ② 订阅关系 | 当前 Consumer 订阅了该产品，或管理员默认可见 | 选择器里没有 |

HiMarket 里一个产品可以上架到多个门户，但**每个门户是一套独立目录**。你在 demo 门户发布，只有从 demo 门户域名进来才看得到；如果当前用的是 `himarket-admin.example.internal`，它属于另一个门户，就看不见。

**排查顺序**：

1. 找一个**能看见的**产品（如 `demo-test`），看它的「门户」页签勾了哪些
2. 把新产品勾成一样的
3. 保存后强刷页面（`Ctrl+Shift+R`），前端有缓存

### 8.5 Consumer 订阅

控制台 → **消费者管理** → 找到当前使用的 Consumer → **订阅 API** → 选择该产品。

若没有合适的 Consumer，新建一个，并确认它已获得该产品的授权（未开启认证的产品可跳过授权）。

### 8.6 HiChat 选择器不显示模型时的定位法

HiChat 有两个入口，**数据源不同**，这是最容易困惑的地方：

| 入口 | 列表来源 |
|---|---|
| 「模型」tab → 点模型 → 发起对话 | 产品**目录**（所有可见产品，含草稿） |
| HiChat「新会话」→ 顶部模型选择器 | **"我可用/已订阅"** 的模型 |

所以"目录里有，选择器里没有"是正常现象。定位方法：

1. `F12` → **Network**
2. 点「新会话」+ 点模型选择器
3. 找拉取模型列表的请求，看 **Response**
4. 有 `test-qwen-32b` → 前端缓存/分类过滤，强刷
5. 没有 → 门户或订阅问题，回 8.4 / 8.5

---

## 9. 阶段七：全链验收

### 9.1 七级验收表

逐级验，不要跳：

| # | 层级 | 命令 | 期望 |
|---|---|---|---|
| 1 | vLLM 直连 | Pod 内 `curl 127.0.0.1:8000/v1/models` | `id = qwen3-32b` |
| 2 | B 集群网关 | `curl -H 'Host: <域名>' http://<B网关>/...` | `200`，秒级 |
| 3 | A→B 网络 | A 集群网关 Pod 内同上 | `200`，秒级 |
| 4 | A 集群路由+插件 | `himarket-server` Pod 内打域名 | `200` |
| 5 | 流式 | 同上加 `"stream":true` | 有 `data:` 帧 |
| 6 | **工具调用** | 带 `tools` 的请求 | 返回 `tool_calls` |
| 7 | HiChat 界面 | 新开会话发消息 | 正常回复 + 思考过程 |

**第 6 级是分水岭**：前五级只证明"能对话"，只有第 6 级通过，MCP 和 Skill 才能用。

### 9.2 工具调用全链验证（必做）

```bash
kubectl -n himarket exec deploy/himarket-server -- \
  curl -s -m 60 http://qwen3.32b.example.internal/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"qwen3-32b",
    "messages":[{"role":"user","content":"北京今天天气怎么样？"}],
    "tools":[{"type":"function","function":{
      "name":"get_weather",
      "description":"查询指定城市的实时天气",
      "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}
    }}],
    "max_tokens":256,
    "chat_template_kwargs":{"enable_thinking":false}
  }'
```

期望出现：

```json
"tool_calls":[{"id":"chatcmpl-tool-...","type":"function",
  "function":{"name":"get_weather","arguments":"{\"city\": \"北京\"}"}}]
```

这一步同时验证了一件事：**ai-proxy 插件和两层网关都不会改写请求体**（否则 `tools` 会被丢掉）。

### 9.3 多轮回传验证

Agent 场景不只需要"发出 tool_calls"，还需要"把工具结果送回去"：

```bash
curl -s -m 60 http://qwen3.32b.example.internal/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"qwen3-32b",
    "messages":[
      {"role":"user","content":"北京今天天气怎么样？"},
      {"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function",
        "function":{"name":"get_weather","arguments":"{\"city\": \"北京\"}"}}]},
      {"role":"tool","tool_call_id":"call_1",
       "content":"{\"city\":\"北京\",\"weather\":\"晴\",\"temp\":\"18C\"}"}
    ],
    "max_tokens":128
  }'
```

期望模型基于工具结果给出结论（如"北京今天晴，18 度"）。

> ⚠️ 上面 `"max_tokens":128` 是**故意写小的反面样本**：第二轮在收到工具结果后要重新推理，
> 128 个 token 连思考都写不完，`</think>` 出不来，正文里就会裸奔 `<think>` 标签，`finish_reason` 会是 `length`。
> 正常调测请给 `2048` 以上；遇到同样症状见 **10.2**。

### 9.4 HiChat 实测

新开会话 → 选模型 → 发一句话 → 挂一个 MCP 试一次。

| 表现 | 含义 |
|---|---|
| 正常回复 + 可折叠「思考过程」 | 全通 |
| 空白 / 一直转圈 | 思考链字段问题，见 7.5 注 |
| `SSE/NDJSON stream failed: null` | 连接层失败，回阶段五 |
| `Retries exhausted: 2/2` | 上游 5xx 被重试耗尽，查网关 `response_flags` |

---

## 10. 故障速查表

按"现象 → 判据 → 根因 → 处理"组织，覆盖本次全部踩坑。

| 现象 | 判据 | 根因 | 处理 |
|---|---|---|---|
| 3~6ms `404` | 有 `route_name`，无非零 `upstream_service_time` | 本地路由没匹配 / host 被抢 | 查 `route_name`，换唯一域名 |
| `404` + `upstream_service_time≈2` | 已转发 | B 集群 Host 不认 | 核对上游主机名与 B 集群 Ingress host |
| `404 route not found` | 来自 kthena-router | 走了 ModelRoute 但没有该模型名 | 补 ModelRoute，`modelName` 与之一致 |
| `503` | 无上游 | 服务来源地址不可达 | 改 NodePort/LB，不用 ClusterIP |
| `400 auto tool choice requires ...` | vLLM 入口拒绝 | 未开 `--enable-auto-tool-choice` | 加参数重启 |
| 带 tools `500`，2ms 结束 | 未到推理引擎 | chat template 无 tools 分支 | 换 tool-trained 模型 |
| `content` 空、仅 `reasoning` | 正常但客户端不认 | 思考链在 separate 字段 | 请求加 `enable_thinking:false` |
| `SSE/NDJSON stream failed: null` | `getent` 退出码 2 | Pod 内 DNS 失败 | hostAliases |
| `Connection refused` | `getent` 有 IP | 网关端口非 80 | patch 成 80 |
| `Retries exhausted: 2/2` | `response_flags=URX` | 上游 5xx 重试超限 | 逐级回退定位 |
| 带 tools 返回 200 但无 `tool_calls` | `content` 里有文本 | parser 与模板格式不匹配 | 换 `--tool-call-parser` |
| 发布了选择器看不到 | F12 Response 无该产品 | 门户不匹配 / 未订阅 | 对齐门户 + 订阅 |
| 一切正常但偶发失败 | 多 Pod 日志不一致 | 只看了 1 个 Pod | 遍历所有网关 Pod |
| 正文里裸露 `<think>…` | 前半段被折叠显示正常，后半段标签外泄 | **生成被 `max_tokens` 截断**，`</think>` 没输出 | 见 10.2，先查产品层「最大输出 Tokens」 |
| 回复说到一半断掉、没结论 | `finish_reason: length` | 同上，token 预算耗尽 | 同上 |
| 配了 `--reasoning-parser qwen3` 却仍有标签外泄 | parser 本身没错 | 标签未闭合，parser 静默失效 | 同上，**不要去改 parser 名** |

### 10.1 通用排障三件套

```bash
# ① 路由到底命中了谁
for p in $(kubectl -n himarket get pods -o name | grep higress-gateway); do
  kubectl -n himarket logs $p --since=5m | grep -i "chat/completions" | tail -3
done

# ② 请求体的真实取值
kubectl -n himarket get wasmplugin <插件名> -o yaml | grep -E "openaiCustomUrl|modelMapping"

# ③ 域名占用情况
kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.rules[*].host}{"\n"}{end}'
```

### 10.2 「话说一半就断 / `<think>` 泄漏」——输出被截断的三层

这是本次最容易误判的故障：症状看着像「vLLM 的 reasoning parser 没配对」，实际改 vLLM 参数完全没用。

**先看现象的确凿特征**：正文在某个词上戛然而止（比如「现在收到了响应，显示当前时间是」后面没有值），
同时 `finish_reason` 是 `length` 而不是 `stop`。**只要看到 `length`，就不要再怀疑 parser。**

**因果链是这样的**：

```
思考太长 → 撞上 max_tokens 上限 → 生成中断 → </think> 没输出
       → parser 找不到闭合标签 → 无法切分 → 整段（含 <think>）当正文返回
```

**往下查之前，先分清三层，它们的名字很像但作用完全不同**：

| 层 | 参数 | 限制的是什么 | 本次实测值 |
|---|---|---|---|
| **HiMarket 产品层** | 产品详情 →「最大输出 Tokens」 | 单次生成的输出上限（即请求体里的 `max_tokens`） | **500 ← 真正的瓶颈** |
| vLLM 服务层 | `--max-model-len` | **输入 + 输出**的上下文总长 | 32768（够用） |
| vLLM 调度层 | `--max-num-batched-tokens` | 单批调度上限，**与输出长度无关** | 16384（别被名字误导） |

**最容易被忽略的是第一层**，因为它在 HiMarket 界面上、不在 vLLM 启动参数里。
500 token 大约只能写 350~400 个汉字；第一轮思考 + `tool_calls` 的结构化 JSON 就快用完了，
第二轮（收到工具结果后重新推理）必然写不完思考和答案。

**处理顺序，从改动成本最低的开始**：

1. **改 HiMarket 产品配置**（不需要重启任何 Pod）：

   | 字段 | 建议值 | 理由 |
   |---|---|---|
   | 最大输出 Tokens | `4096` | 给思考留足空间，这是最优先的一条 |
   | 温度 | `0.3~0.5` | 工具调用要稳定；温度高会把参数编错，也可能写坏 `tool_calls` 的 JSON |

   保存后重开一个对话再测——旧对话历史里已混进残缺的 `<think>` 文本，会干扰模型对新一轮格式的判断。

2. **仍然截断**，说明 HiChat 侧可能把 `max_tokens` 写死了。这时才动 vLLM，在 3.2 的参数里加一条：

   ```yaml
   --default-chat-template-kwargs '{"enable_thinking": false}'
   ```

   模板就不再输出 `<think>`，没有「思考吃预算」这回事。**工具调用不受影响**——
   那是 `--tool-call-parser hermes` 的职责，与 thinking 是两套独立机制，关了照样能调工具。

3. **确实要保留思考过程**（给人看判断依据）才走这条路，且必须三件事同时做到，缺一件就复现同样症状：

   - HiMarket 产品「最大输出 Tokens」≥ 4096
   - `--max-model-len` 放到 40960（Qwen3-32B 原生上限）
   - 接受响应时间翻倍、token 消耗翻倍

**一条判定捷径**：同一个模型、同一套 vLLM 参数，用 Chatbox 之类**直连**模型的客户端提问不截断，
经 HiMarket 就截断——那就百分之百是第一层（产品配置），和 vLLM 无关。

---

## 11. 变更与回滚

### 11.1 会丢配置的三个操作

| 操作 | 影响 | 预防 |
|---|---|---|
| `kubectl patch --type merge hostAliases` | 整段替换数组 | 先读旧值，一起写入 |
| Helm 重装 himarket-server | hostAliases 丢失 | 记入部署清单，或用内部 DNS |
| 控制台重建 AI 路由 | 域名/注解可能变 | 改前导出 yaml 备份 |

### 11.2 备份命令

```bash
kubectl -n himarket get deploy himarket-server -o yaml > himarket-server-backup.yaml
kubectl get ingress -A -o yaml > ingress-backup.yaml
kubectl get mcpbridge -A -o yaml > mcpbridge-backup.yaml
```

### 11.3 回滚顺序

链路上游先回，下游后回，避免中间态：

```
① 停用 AI 路由（或改域名回旧值）
② 恢复 AI 服务提供者
③ 恢复服务来源
④ 恢复产品关联
⑤ 恢复 hostAliases
```

每一步后都跑一次阶段五的三步验收，确认退回到上一可用状态。

### 11.4 vLLM 回滚

```bash
kubectl -n kthena-system rollout undo deploy/vllm-qwen3-32b
# 或直接用备份的 yaml
kubectl apply -f vllm-qwen3-32b-deploy.yaml
```

注意：8 卡独占场景下 `strategy` 必须是 `Recreate`，滚动更新会因卡不足卡死。

---

## 附录 A：本次实测参数

| 项 | 值 |
|---|---|
| 对外域名 | `qwen3.32b.example.internal`（**点号**） |
| AI 路由对象 | `himarket/ai-route-qwen3.32b.internal` |
| A 集群网关 ClusterIP | `<HIMARKET_GW_IP>`（`himarket/higress-gateway`） |
| B 集群网关 | `<MODEL_GW_IP>:30081` |
| 模型侧 Service | `kthena-system/vllm-qwen3-32b:8000` |
| 模型名 | `qwen3-32b` |
| hostAliases | `{"ip":"<HIMARKET_GW_IP>","hostnames":["qwen3.32b.example.internal"]}` |

**命名不一致是刻意的，不要"统一"**：

- 域名里是 `qwen3.32b`（点）
- 模型名是 `qwen3-32b`（横线）

前者是路由 host，后者是 vLLM 的 served name，混了会 `404 model not found`。

### 实测通过记录

```
$ kubectl -n himarket exec deploy/himarket-server -- getent hosts qwen3.32b.example.internal
<HIMARKET_GW_IP>    qwen3.32b.example.internal

$ ... curl -w '%{http_code} %{time_total}s\n' http://qwen3.32b.example.internal/v1/chat/completions
200 0.394360s

$ ... curl -sN ... "stream":true
data: {"id":"chatcmpl-...","choices":[{"delta":{"role":"assistant","content":""}}]}
data: {"id":"chatcmpl-...","choices":[{"delta":{"reasoning":"\n"}}]}
```

---

## 附录 B：命令速查

### 取值

```bash
kubectl -n kthena-system get svc | grep vllm
kubectl -n higress-system get svc | grep higress-gateway
kubectl get ingressclass
kubectl -n himarket get svc higress-gateway -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl get mcpbridge -A
```

### 验收

```bash
# 模型侧
curl -s -m 30 http://<B网关>/v1/chat/completions -H 'Host: <域名>' \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-32b","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'

# A 集群侧
kubectl -n himarket exec deploy/himarket-server -- getent hosts <域名>
kubectl -n himarket exec deploy/himarket-server -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' \
  http://<域名>/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-32b","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

### 排障

```bash
# 路由命中
for p in $(kubectl -n himarket get pods -o name | grep higress-gateway); do
  kubectl -n himarket logs $p --since=5m | grep -i "chat/completions" | tail -3
done

# 域名占用
kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.rules[*].host}{"\n"}{end}'

# 插件配置
kubectl -n himarket get wasmplugin -o yaml | grep -E "openaiCustomUrl|modelMapping"

# hostAliases 现状
kubectl -n himarket get deploy himarket-server -o jsonpath='{.spec.template.spec.hostAliases}{"\n"}'
```

---

## 附录 C：术语对照

| 术语 | 含义 |
|---|---|
| 服务来源 | Higress 的上游注册表，即 McpBridge 的 registry；跨集群用 `type: static` |
| AI 服务提供者 | ai-proxy 插件配置，定义上游服务、路径、Host |
| AI 路由 | 域名 + 路径 + 服务的绑定关系，由控制台生成 Ingress 与 WasmPlugin |
| 下游域名 | 客户端访问使用的域名 |
| 上游 Host | 转发给模型集群时携带的 Host 头 |
| served-model-name | vLLM 对外暴露的模型 ID，必须与请求体 `model` 一致 |
| chat template | 模型目录里的 Jinja2 模板，决定 messages+ 如何渲染成 prompt |
| PD 分离 | Prefill/Decode 拆成不同角色部署，Kthena ModelServer 的 `pdGroup` 依赖此拓扑 |
| `response_flags` | Envoy 响应标记：`URX` 重试超限、`UF` 上游连接失败、`NR` 无路由 |
| `enable_thinking` | chat template 里的开关，决定模型是否先输出 `<think>` 思考段（Qwen3 混合推理模型特有） |
| `reasoning_content` | OpenAI 兼容接口的独立字段，`--reasoning-parser` 把思考段切到这里，与 `content` 分开 |
| `finish_reason` | 生成结束原因：`stop` 正常结束、`length` 撞 max_tokens 上限被截断 |
| `max_tokens` | 单次生成的输出上限，HiMarket 产品层配置项；**不等于** `--max-model-len` |
