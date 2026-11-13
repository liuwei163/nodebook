# 生产级 MCP 全链路接入手册

> 目标不是「能连通」，而是**可重复部署、可分层验证、可灰度回滚、可审计追踪**。
>
> 与 PoC 版的区别，一句话概括：
> PoC 是「手工点、直连、单副本、无鉴权」，生产是「声明式、经注册中心、多副本、有边界」。

---

## 0　先建立一个整体图

整条链路上有五个角色，各自只干一件事。理解这一点，后面所有配置都能归位：

```
┌─────────────────────────────────────────────────────────────────────┐
│  控制面   HiMarket                                                  │
│           产品定义 / 订阅授权 / 门户展示 / 用量统计                    │
│           回答：谁能用、能用多少                                       │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ 产品关联一个 MCP 地址
┌──────────────────────────▼──────────────────────────────────────────┐
│  入口面   Higress                                                   │
│           /mcp-servers/<名字>/<路径> 路由、鉴权、限流、审计、TLS        │
│           回答：请求能不能进、进多少、留没留痕                          │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ McpBridge 从 Nacos 拉实例列表
┌──────────────────────────▼──────────────────────────────────────────┐
│  注册面   Nacos                                                     │
│           服务名 → 实例 IP 列表 + 元数据（transport/path/owner）       │
│           回答：现在有哪些可用的实例、在哪                            │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ 直连 Pod IP
┌──────────────────────────▼──────────────────────────────────────────┐
│  运行时   MCP Server Pod（2 副本）                                   │
│           工具实现：查时间、查工单、查资产……                           │
│           回答：具体做什么                                            │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ 最小权限访问
┌──────────────────────────▼──────────────────────────────────────────┐
│  数据面   内网系统（DB / CMDB / 工单 / 监控）                          │
└─────────────────────────────────────────────────────────────────────┘
```

**五层之间是逐层依赖，所以验证必须自下而上。** 反过来查（先看 HiChat 为什么没反应）几乎不可能定位，因为任何一层断掉，最上层的表现都是同一句话——「工具执行失败」。

---

## 1　阶段一：命名空间与租户规划

### 1.1 为什么要单独规划，不能沿用 public

现有环境是：`public` 命名空间 + 4 个遗留 UUID 空间（`worst-test`、`sdfas`、`test_hw`、`worst-tst`），分组混用 `DEFAULT_GROUP` 和 `mcp-endpoints`。这套形态在单人验证时没有成本，但生产上有三个具体问题：

| 问题 | 后果 |
|---|---|
| 业务微服务和 MCP 混在同一命名空间 | 网关订阅 `public` 等于把全部微服务都暴露给 MCP 发现逻辑，靠 `allowMcpServers` 白名单兜底，白名单漏一个就是一个漏洞 |
| 分组被当成环境隔离用 | 测试环境的服务可能因为分组配错而出现在生产域名下 |
| 遗留命名空间无人清理 | 「服务列表」这个唯一视图里混着死实例，排障时先要花十分钟分辨哪些是真的 |

### 1.2 规划方案

```
集群层（环境隔离，靠集群不靠 namespace）
  ├─ prod 集群   → Nacos: nacos-prod
  └─ sit 集群    → Nacos: nacos-sit

Nacos 命名空间层（业务域隔离）
  prod/nacos-prod
  ├─ public          存量业务微服务（保持不动）
  └─ ai-mcp          ★ 新建：所有 MCP Server 归这里

分组层（同域内的技术分组）
  ai-mcp 下
  └─ MCP_PROD        所有生产 MCP

服务层
  └─ mini-mcp        带域前缀更规范：ai-mini-mcp / ai-cmdb-mcp
```

**为什么不把环境也做成 namespace**：namespace 是逻辑隔离，同一个 Nacos 集群下所有命名空间共享存储、CPU/内存、版本升级、故障域。生产流量和测试流量共用一个 Nacos，测试环境一次误操作就可能影响生产。

### 1.3 操作步骤

Nacos 控制台 → 命名空间 → 新建：

| 字段 | 值 | 说明 |
|---|---|---|
| 命名空间 ID | `ai-mcp` | **这个 ID 后面要填到 McpBridge 的 `nacosNamespaceId`**，建议自定义成可读字符串，别用自动生成的 UUID |
| 命名空间名称 | `AI MCP` | 仅展示用 |
| 描述 | `AI 平台 MCP Server 注册空间` | |

创建后确认列表里能看到 `ai-mcp`，且**命名空间 ID 那一列显示的是 `ai-mcp` 而不是一串 UUID**。如果显示 UUID，说明你们 Nacos 版本不支持自定义 ID，把这个 UUID 记下来，后面 `NACOS_NAMESPACE` 和 `nacosNamespaceId` 都要填它。

> **知识点：namespaceId 与 namespace 名称是两个东西。**
> API 调用和 McpBridge 用的是 `namespaceId`（唯一标识），控制台界面上看的是名称。
> 填错成名称是最常见的错误之一，表现是「服务注册成功了但网关看不见」。

---

## 2　阶段二：MCP Server 生产化

### 2.1 为什么不能继续用 ConfigMap 挂脚本

PoC 阶段用 `kubeflow/python:3.7` + ConfigMap 装代码，能跑，但五个方面不合格：

| 维度 | PoC 做法 | 生产问题 |
|---|---|---|
| 可复现 | 依赖上游镜像 tag | tag 可能被覆盖，今天跑的和明天不是同一份制品 |
| 版本管理 | ConfigMap 内容变更无历史 | 出问题回不到上一版，只能凭记忆改回去 |
| 大小 | ConfigMap 单条上限 1MiB | 代码稍大就挂不下 |
| 权限 | 镜像默认 root | 被攻破后可写文件、可提权 |
| 安全扫描 | 扫不了 | 安全团队无法做镜像合规检查 |

### 2.2 构建生产镜像

```bash
# 把 Dockerfile 拷到代码目录，或直接用 -f 指定
cd k8s/mini-mcp
cp ../prod-mcp/Dockerfile .

# BASE_IMAGE 按你们 Harbor 里实际有的 python 镜像替换
docker build \
  --build-arg BASE_IMAGE=harbor.example.internal/ai-platform/python:3.11-slim \
  -t harbor.example.internal/ai-platform/mini-mcp:1.2.0 .

docker push harbor.example.internal/ai-platform/mini-mcp:1.2.0
```

离线环境：在能联网的机器上 `docker save mini-mcp:1.2.0 | gzip > mini-mcp-1.2.0.tar.gz`，传进内网后 `docker load -i`，再 push 到内网 Harbor。

镜像做的四件事：非 root（UID 10001）、预编译字节码（只读根文件系统下不写 `.pyc`）、`PYTHONUNBUFFERED`（日志实时可见）、健康检查。

### 2.3 部署

```bash
# 1. 创建 SA（不需要任何 RBAC 权限）
kubectl apply -f prod-mcp/02-mcp-server-prod.yaml

# 2. 注册器脚本进 ConfigMap（sidecar 挂载用）
kubectl -n himarket create configmap nacos-register-script \
  --from-file=nacos-register.sh=prod-mcp/nacos-register.sh \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Nacos 凭据（开启鉴权时必需）
kubectl -n himarket create secret generic nacos-mcp-auth \
  --from-literal=username='nacos' \
  --from-literal=password='你的密码'

# 4. 确认镜像路径改对了
grep -n 'image:' prod-mcp/02-mcp-server-prod.yaml
```

### 2.4 三个探针为什么不能省

这是生产化里最容易被简化、又最容易出事故的部分：

| 探针 | 失败动作 | 用来防什么 |
|---|---|---|
| `startupProbe` | 重启容器 | 启动慢时被 liveness 误杀，造成无限重启循环 |
| `readinessProbe` | 从 Endpoints 移除，不重启 | 流量打到还没准备好的 Pod |
| `livenessProbe` | 重启容器 | 进程僵死（HTTP 还应答但逻辑不动） |

**这个清单里 liveness 用的是自定义脚本而不是 `httpGet: /healthz`**，理由值得记住：

`/healthz` 只能证明「HTTP 服务器还在 accept 连接」。如果 MCP 的 JSON-RPC 分发逻辑卡死、线程池耗尽、或者工具注册表被清空，`/healthz` 照样返回 200，但这个 Pod 已经不能服务了。所以 liveness 直接发一次 `tools/list`，校验返回里真的有工具——这才是「活着」的定义。

代价是每次检查多启动一个 Python 进程（约 50ms），在 20 秒间隔下可以忽略。

### 2.5 NetworkPolicy 的边界

清单里入站只放行两个来源：

- `app=higress-gateway` 的 Pod（经网关的正常流量）
- `app=himarket-server` 的 Pod（HiChat 直连模式）

出站默认拒绝，只放开 DNS 和 Nacos。**这是刻意的**：MCP 工具天然能访问内网，所以它必须是「知道自己能去哪」的。等 mini-mcp 真的需要查 CMDB 时，再在那段注释里逐条放开，用一次加一条。

---

## 3　阶段三：注册到 Nacos

### 3.1 三种注册方式的取舍

| 方式 | 适用 | 代价 |
|---|---|---|
| 手工控制台建实例 | 一次性验证 | 无生命周期，Pod 重建后变幽灵实例，没人敢删 |
| sidecar 自动注册（本方案） | 副本会伸缩、IP 会变 | 多一个容器，脚本要维护 |
| 应用内集成 SDK | Java/Go 服务 | Python MCP 不想引依赖；业务代码被注册逻辑污染 |

**还有第四种，很多生产环境在用**：不注册到 Nacos，用 `type: static` 直接写固定的 Service 域名。适用条件是「服务名不变、副本数固定」。

判断标准：如果 mini-mcp 会扩到 6 副本、Pod IP 会变，就走 Nacos；如果永远 1~2 副本且用 Service 名访问，`type: static` 更简单可靠——少一层依赖就少一个故障点。

本手册按 Nacos 走，因为你要学这套配置。

### 3.2 注册器做了什么

`nacos-register.sh` 作为 sidecar 长期运行，逻辑是：

```
1. 换 accessToken（Nacos 开启鉴权时）
2. 等本地 127.0.0.1:8765/healthz 通了才注册  ← 关键：主容器没起来不注册
3. 调 Nacos OpenAPI 注册实例（带元数据）
4. 每 5 秒：本地健康 → 发心跳；不健康 → 主动注销
5. 收到 SIGTERM → 注销 → 退出
```

第 2 步和第 4 步是它比手工注册强的地方：**流量永远不会被导到一个不能服务的 Pod**。即使主容器崩溃重启，注册器感知到本地不健康会立刻把实例摘掉，恢复后再挂回来。

### 3.3 元数据是网关的路由依据

脚本注册时带上了这组元数据：

```
transport=streamable-http, path=/mcp, owner=ai-platform, version=1.2.0, env=prod, protocol=mcp
```

`transport` 和 `path` 最关键。**缺了它们，网关只能按默认值猜**——猜错的表现就是「工具列表一直是空的」，而且日志里没有任何报错，极难排查。

你们之前 `test` 那个服务连不通，原因之一就是实例信息不完整（IP 字段填了 `http://www.baidu.com:80` 这种完整 URL），网关拼出来的上游地址是无效的。

### 3.4 验证注册结果

```bash
# 在跳板机上直接查 Nacos OpenAPI，不依赖控制台
curl -sS "http://nacos.himarket.svc.cluster.local:8848/nacos/v1/ns/instance/list?serviceName=mini-mcp&groupName=MCP_PROD&namespaceId=ai-mcp" | python3 -m json.tool
```

期望看到 `hosts` 数组里有 2 个条目（2 副本），每个都是 Pod IP，`healthy: true`，`metadata` 里能看到 `transport` 和 `path`。

如果 `hosts` 为空 → 注册失败，看 sidecar 日志：

```bash
kubectl -n himarket logs deploy/mini-mcp -c nacos-registrar --tail=30
```

日志里每一步都有明确输出（「注册成功」「心跳发送失败」「本地健康检查失败，主动摘除流量」），比猜快得多。

### 3.5 临时实例 vs 持久实例

| | 临时（ephemeral=true） | 持久（ephemeral=false） |
|---|---|---|
| 健康判定 | 客户端发心跳，5s 没心跳标记不健康，15s 摘除 | Nacos 主动 TCP 探测 |
| 自愈速度 | **快**（15s 内摘干净） | 取决于探测周期，通常 30s+ |
| Nacos 负载 | 心跳请求多（每实例 5s 一次） | 低 |
| 适用 | 副本会动态伸缩、进程崩溃需快速摘除 | 实例稳定、想减少 Nacos 压力 |

本方案选临时实例，因为 sidecar 和主容器同生共死，心跳天然反映真实健康状态。

---

## 4　阶段四：Higress 接入

### 4.1 McpBridge 的五个关键字段

先理解这张表，配置时不会盲填：

| 字段 | 作用 | 填错的后果 |
|---|---|---|
| `nacosNamespaceId` | 订阅哪个命名空间 | 服务注册成功但网关看不见，**无任何报错** |
| `nacosGroups` | 订阅哪些分组（数组） | 同上，且是整体替换，容易误删别人的分组 |
| `allowMcpServers` | 哪些服务允许作为 MCP 暴露 | 不在名单里的服务不会生成路由，返回 404 |
| `mcpServerBaseUrl` | 暴露路径前缀 | 必须 `/` 开头结尾；写成 `mcp-servers` 会导致路由不匹配 |
| `mcpServerExportDomains` | 允许的 Host | Host 不匹配直接拒绝，表现为 404 或 403 |

### 4.2 路径映射规则（最容易错的地方）

```
外部:  http://mcp-prod.example.internal/mcp-servers/mini-mcp/mcp
                        └─ baseUrl ─┘ └─服务名─┘ └透传┘
内部:  http://<PodIP>:8765/mcp
```

**`mcp-servers` 和 `mini-mcp` 这两段会被剥掉，剩下的 `/mcp` 原样转发。**

所以：服务实际监听 `/mcp`，外部地址就必须带 `/mcp` 后缀。只写 `http://mcp-prod.example.internal/mcp-servers/mini-mcp` 的话，网关会转发到 `/`，服务返回的是健康检查 JSON，MCP 握手必然失败——而报错只会说「解析响应失败」，看不出是路径问题。

### 4.3 为什么只暴露 Streamable HTTP，不暴露 SSE

SSE 的服务端在握手时返回：

```
event: endpoint
data: /message?sessionId=abc123
```

这个 `/message` 是服务自己生成的**绝对路径**，不包含网关前缀。客户端拿到后会去请求 `http://mcp-prod.example.internal/message?sessionId=abc123`，丢了 `/mcp-servers/mini-mcp` 两段，直接 404。

要修就得在网关做响应体改写（正则替换 SSE 流里的路径），既麻烦又脆弱——服务端换个路径格式就失效。

Streamable HTTP 是无状态 POST，请求即响应，不存在这个问题。**这也是为什么 MCP 规范在 2025-03-26 版本引入了 Streamable HTTP 来替代 SSE。**

### 4.4 应用配置

```bash
# 方式 A（推荐，GitOps）：整体 apply，清单里已包含现有 4 条 registry
kubectl apply -f prod-mcp/03-higress-mcpbridge-prod.yaml
```

```bash
# 方式 B（渐进）：只追加一条 registry，不碰现有配置
kubectl -n himarket patch mcpbridge default --type json -p '[
 {"op":"add","path":"/spec/registries/-","value":{
   "name":"company-nacos-ai",
   "type":"nacos3",
   "domain":"nacos.himarket.svc.cluster.local",
   "port":8848,
   "nacosNamespaceId":"ai-mcp",
   "nacosGroups":["MCP_PROD"],
   "allowMcpServers":["mini-mcp"],
   "enableMCPServer":true,
   "mcpServerBaseUrl":"/mcp-servers/",
   "mcpServerExportDomains":["mcp-prod.example.internal"],
   "authSecretName":"open-platform-higress-nacos",
   "vport":{"default":8080}
 }}]'
```

**改完必须回读**，不要相信 patch 的返回值（你们已经踩过一次「patch 返回成功但值没变」的坑）：

```bash
kubectl -n himarket get mcpbridge default -o jsonpath='{range .spec.registries[*]}{.name}{"\t"}{.nacosNamespaceId}{"\t"}{.allowMcpServers}{"\n"}{end}'
```

### 4.5 域名接入

McpBridge 只生成路由，不让域名指过来。`mcp-prod.example.internal` 需要两处能解析：

**集群内**（himarket-server 进程访问）→ hostAliases：

```bash
# ⚠️ merge patch 会整段替换 hostAliases，必须先读全量再整体写
kubectl -n himarket get deploy himarket-server -o jsonpath='{.spec.template.spec.hostAliases}'
```

拿到现有内容后，把新域名加进同一个 IP 的 hostnames 数组，整体 patch。

**集群外**（外部消费者）→ 正式 DNS 记录指向 `higress-gateway` 的 LoadBalancer IP 或 NodePort。当前 `higress-gateway` 是 `LoadBalancer` 且 `EXTERNAL-IP: <pending>`（没有 LB 实现），所以实际入口是 NodePort `30080`。生产环境应该配好 LB 或前面挂 F5。

### 4.6 网关层的鉴权与限流

`03-higress-mcpbridge-prod.yaml` 里给了两个 WasmPlugin 的配置，都是可选的，与 HiMarket 订阅构成纵深防御：

| 层 | 控制什么 | 缺了会怎样 |
|---|---|---|
| HiMarket 订阅 | 谁能**看到**这个产品 | 没有自助入口，用户不知道自己能用什么 |
| 网关 key-auth | 请求能不能**到达**后端 | 集群内任何能解析域名的东西都能绕过订阅直接调 |

限流按 `x-api-key` 计数，阈值要按「工具调用次数」估，不是「会话数」——一次对话可能连续触发多次 `tools/call`。配置里给的 60 次/分钟大致对应 10~15 轮带工具的对话。

---

## 5　阶段五：HiMarket 产品化

### 5.1 建产品

API 产品 → MCP Server 标签 → 「+ 创建」（**不是三条导入**，导入要求外部已注册完整元数据）：

| 字段 | 值 |
|---|---|
| 名称 | `ai-time-mcp` |
| 描述 | 生产 MCP：时间查询、文本回显、数值计算 |
| 类型 | MCP Server（预填） |
| 产品类别 | `agent类别` |

### 5.2 配地址（真正关键的一步）

创建只是建了个空壳——这也是为什么旧的 `test` 一直显示「待配置」，且 HiChat 勾选它就崩：壳建了、地址没填，`transportConfig` 是 null，`ChatService.buildMCPConfigs:427` 直接空指针。

进详情页 → 关联 API → 标准创建：

| 字段 | 值 |
|---|---|
| 名称 | `ai-time-mcp-api` |
| 类型 | MCP Server |
| 传输方式 | **Streamable HTTP** |
| 地址 | `http://mcp-prod.example.internal/mcp-servers/mini-mcp/mcp` |

地址三段都不能错：Host 必须在 `mcpServerExportDomains` 里、前缀必须是 `/mcp-servers/`、后缀必须是服务真实路径 `/mcp`。

保存后点「刷新工具列表」，应出现 `get_time`、`echo`、`add` 三个。

### 5.3 发布与订阅

1. 产品详情 → 发布 → 选择门户
2. 门户侧确认产品可见
3. 用另一个账号（Consumer）订阅
4. HiChat 里勾选这个 MCP

---

## 6　阶段六：可观测性

生产系统出问题时，最快的路径是「看指标发现问题 → 看日志定位原因 → 看链路找到调用方」。

### 6.1 三处必须有的日志

| 位置 | 看什么 | 命令 |
|---|---|---|
| MCP Server | 每个请求的路径、状态码、耗时 | `kubectl -n himarket logs deploy/mini-mcp -c mcp-server` |
| 注册器 | 注册/心跳/摘除事件 | `kubectl -n himarket logs deploy/mini-mcp -c nacos-registrar` |
| 网关访问日志 | 上游地址、响应码、延迟 | Higress 控制台 → 可观测 → 日志，或接 SLS/Loki |

**判断流量走向的一个技巧**：MCP Server 日志里如果一条新记录都没有，说明请求根本没到——问题在网关或 Nacos；如果有记录但客户端报错，问题在响应格式或鉴权。

### 6.2 指标

MCP Server 目前没有 `/metrics`，这是待补项。最小可用的四个指标：

| 指标 | 类型 | 用途 |
|---|---|---|
| `mcp_requests_total{tool,status}` | Counter | 每个工具的调用量和失败率 |
| `mcp_request_duration_seconds{tool}` | Histogram | P95 延迟，识别慢工具 |
| `mcp_active_requests` | Gauge | 在途请求数——**这才是 HPA 该用的指标**，比 CPU 灵敏得多 |
| `mcp_tools_registered` | Gauge | 工具数量，异常归零说明初始化失败 |

补上 `/metrics` 后，用 `ServiceMonitor` 抓取，HPA 换成自定义指标：

```yaml
metrics:
  - type: Pods
    pods:
      metric:
        name: mcp_active_requests
      target:
        type: AverageValue
        averageValue: "20"
```

### 6.3 告警（按优先级）

| 告警 | 条件 | 含义 |
|---|---|---|
| MCP 不可用 | 网关 5xx 比例 > 5% 持续 3 分钟 | 服务或上游异常 |
| 全副本不健康 | Nacos 健康实例数 = 0 | 服务整体挂了，立刻处理 |
| 延迟恶化 | P95 > 3s 持续 5 分钟 | 后端系统变慢，或工具逻辑有问题 |
| 工具调用失败 | `mcp_requests_total{status="error"}` 增速异常 | 具体某个工具坏了 |
| 注册器异常 | sidecar 重启次数 > 3/小时 | Nacos 连接或凭据有问题 |

---

## 7　验证矩阵

**必须自下而上，任何一层不通就不要往上走**，否则上层报错无法定位。

| 层 | 验证内容 | 命令 | 期望 |
|---|---|---|---|
| L1 | 容器内自检 | `kubectl -n himarket exec deploy/mini-mcp -c mcp-server -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8765/healthz').read())"` | `{"status":"ok",...}` |
| L2 | 集群内 Service 可达 | `kubectl -n himarket exec deploy/himarket-server -- curl -sS http://mini-mcp:8765/healthz` | 同上 |
| L3 | Nacos 已注册且健康 | `curl -sS ".../instance/list?serviceName=mini-mcp&groupName=MCP_PROD&namespaceId=ai-mcp"` | `hosts` 有 2 条，`healthy:true` |
| L4 | 网关能按服务名路由 | `kubectl -n himarket exec deploy/himarket-server -- curl -sS -X POST http://mcp-prod.example.internal/mcp-servers/mini-mcp/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"initialize",...}'` | 返回含 `"serverInfo":{"name":"mini-mcp"}` |
| L5 | 工具列表可拉取 | 同上，方法换 `tools/list` | 三个工具 |
| L6 | HiMarket 产品能刷新工具 | 界面点「刷新工具列表」 | 显示 3 个工具 |
| L7 | HiChat 端到端 | 问「现在几点」 | 返回真实时间，且有工具调用卡片 |

### 7.1 故障注入（验证保护机制真的生效）

只做正向验证是不够的，生产上要确认「坏的时候会怎样」：

```bash
# 1. 杀一个副本，确认服务不中断、Nacos 实例数自动恢复
kubectl -n himarket delete pod -l app=mini-mcp --field-selector=status.phase=Running --wait=false

# 2. 摘掉白名单，确认网关拒绝（应该返回 404 route not found）
kubectl -n himarket patch mcpbridge default --type json -p '[{"op":"replace","path":"/spec/registries/4/allowMcpServers","value":[]}]'
# 验完记得改回来

# 3. 模拟工具卡死，确认 liveness 能重启
kubectl -n himarket exec deploy/mini-mcp -c mcp-server -- sh -c 'kill -STOP 1'
```

---

## 8　故障诊断表

按「现象 → 最可能的层 → 具体检查」组织：

| 现象 | 层 | 检查 |
|---|---|---|
| `404 route not found` | 网关 | ① 服务名是否在 `allowMcpServers` ② Host 是否在 `mcpServerExportDomains` ③ 路径是否带 `/mcp-servers/` |
| `503 no healthy upstream` | Nacos | ① 实例健康数是否为 0 ② 注册的 IP 是否是纯 IP（不是 URL）③ 权重是否为 0 |
| `Host not allowed` / 403 | 网关 | `mcpServerExportDomains` 里没有这个域名 |
| 连接超时 | 网络 | NetworkPolicy 是否放行了网关；`kubectl exec` 到网关 Pod 里 curl 后端 |
| 工具列表为空，日志无请求 | 网关 | 地址写错，请求根本没发出来 |
| 工具列表为空，日志有请求 | 协议 | 传输方式选错（应为 Streamable HTTP）；或路径少了 `/mcp` |
| 刷新工具列表报 500 / 空指针 | HiMarket | 产品壳建了但没配地址（`transportConfig` 为 null） |
| 工具能调但回答是编的 | 模型 | vLLM 是否带 `--enable-auto-tool-choice --tool-call-parser hermes` |
| 正文出现残留 `<think>` | 模型 | `max_tokens` 太小导致思考未闭合，调大到 4096 或关闭 `enable_thinking` |
| HiChat 勾选就 500，不勾正常 | 产品 | 该产品的 MCP 配置不完整，取消勾选后逐个排除 |

---

## 9　变更与回滚

### 9.1 变更顺序

生产上任何一次变更，顺序固定为：

```
1. 改配置 → 2. 灰度（1 个副本）→ 3. 验证 L1-L5 → 4. 全量 → 5. 再验证 → 6. 记录
```

MCP Server 的灰度：

```bash
# 只更新 1 个副本，观察 10 分钟
kubectl -n himarket set image deploy/mini-mcp mcp-server=harbor.example.internal/ai-platform-prod/mini-mcp:1.2.1
kubectl -n himarket rollout status deploy/mini-mcp
```

因为 `maxUnavailable: 0`，滚动更新期间服务不会中断。

### 9.2 回滚

```bash
# 镜像回滚
kubectl -n himarket rollout undo deploy/mini-mcp
kubectl -n himarket rollout status deploy/mini-mcp

# 网关配置回滚（McpBridge）
kubectl -n himarket rollout history  # 不适用 CR，改用 Git 回退
git revert <commit> && kubectl apply -f prod-mcp/03-higress-mcpbridge-prod.yaml
```

**McpBridge 这类 CR 没有 `rollout undo`**，所以生产上必须把配置放 Git。每次 apply 前 `kubectl get -o yaml > backup/mcpbridge-$(date +%F-%H%M).yaml`，这是最省事的兜底。

### 9.3 变更检查单

- [ ] 新镜像已推送到 Harbor，且 tag 不可变（用版本号，不用 `latest`）
- [ ] 副本数、资源限制按预期变化（避免误改导致 OOMKilled）
- [ ] Nacos 元数据里的 version 已更新
- [ ] `allowMcpServers` 只增不减（除非确认要下线某个服务）
- [ ] 有回滚方案，且已备份当前配置

---

## 10　学习要点速查

### Nacos 三层结构

| 层 | 作用 | 常见误用 |
|---|---|---|
| namespace | 租户/环境隔离，服务名可重名 | 拿它做环境隔离却共用集群（隔离不彻底） |
| group | 同域内的技术分组 | 拿它做环境隔离（权限模型不支持） |
| service | 一组等价实例 | 服务名不带业务前缀，列表里分不清 |

**Nacos 的健康检查机制**：

- 临时实例（ephemeral=true）：客户端心跳。5s 无心跳 → 不健康，15s → 摘除
- 持久实例（ephemeral=false）：Nacos 主动 TCP/HTTP 探测
- 保护阈值：健康实例占比低于阈值时，**连不健康的实例也返回**（防止流量全断）。设 0 关闭

### Higress 路由优先级

```
精确域名 + 精确路径  >  精确域名 + 前缀路径  >  通配域名
```

MCP 的路由是 McpBridge 根据 `mcpServerExportDomains` + `mcpServerBaseUrl` + 服务名自动生成的，优先级高于普通 Ingress。所以同一个域名下如果既有普通 Ingress 又有 MCP 路由，路径不要重叠。

### McpBridge 的 vport

`vport` 是「虚拟端口映射」，把注册中心发现的服务绑定到网关的指定监听端口。作用是**多注册中心下的同名服务隔离**——两个 Nacos 都注册了 `order-service`，靠 `vport` 区分谁是谁。

对 MCP 的 HTTP 暴露，`vport` 不参与——MCP 走的是 `mcpServerBaseUrl` 的路径匹配，挂在标准 80/443 listener 上。所以看到 `vport: default: 8080` 不用去访问 8080 端口。

---

## 11　待确认项

执行前需要你确认这四项，否则命令里的占位符填不准：

| 项 | 怎么取 |
|---|---|
| Harbor 镜像路径 | `kubectl -n himarket get deploy himarket-server -o jsonpath='{.spec.template.spec.containers[0].image}'` |
| 镜像拉取凭据名 | `kubectl -n himarket get deploy himarket-server -o jsonpath='{.spec.template.spec.imagePullSecrets}'` |
| Nacos 是否开鉴权 | mcpbridge 里有 `authSecretName` 说明开了；密码问运维 |
| 是否有 Redis | 限流插件 `cluster-key-rate-limit` 依赖它；没有就换 `local-rate-limit` |
