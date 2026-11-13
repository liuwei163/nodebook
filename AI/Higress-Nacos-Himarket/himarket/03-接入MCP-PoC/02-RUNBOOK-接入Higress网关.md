# 通过 Higress 网关接入 mini-mcp（绕开 HiMarket v0.8.2 的 Nacos 导入缺陷）

## ⭐ 更新（2026-11-13）：最短路径是控制台「创建 MCP 服务 → 直接路由」

实测发现：**Higress 控制台「后端服务」下拉里已经能选到 Nacos 发现的
`mini-mcp::1.0.0.mcp-endpoints...`**，说明 Nacos 服务发现本来就是通的。
因此下面 8 个阶段里的「改 mcpbridge 白名单 / nacosGroups」**完全不需要做**。

在 `AI 网关管理 → MCP 管理 → + 创建MCP服务` 里直接填：

| 字段 | 值 |
|---|---|
| 服务名称 | `mini-mcp`（报重名则改 `mini-mcp-gw`） |
| 描述 | 任意 |
| MCP 接入点域名 | 选 `mcpServerExportDomains` 里的那个真实域名 |
| 服务类型 | **直接路由** |
| 后端服务 · 服务名称 | 下拉选 `mini-mcp::1.0.0.mcp-endpoints...`（Nacos 发现的服务） |
| 服务协议 | `MCP`（自动带出，灰显） |
| MCP Transport | `HTTP`（对应 Streamable HTTP） |
| 路径 | `/mcp`（**这是后端路径**） |

创建后详情页会给出两条接入点，以界面的灰色预览为准：

- Streamable HTTP：`http://<域名>/mcp-servers/mini-mcp`
- SSE：`http://<域名>/mcp-servers/mini-mcp/sse`

⚠️ **对外路径不带 `/mcp` 尾巴**。表单里的「路径 `/mcp`」是后端路径，网关转发时
自己拼；把它手工加到对外 URL 上会 404。这是与早期假设不同的一点。

这条路同时满足三件事：流量经过 Higress（鉴权 / 限流 / 访问日志）、
**保留 Nacos 服务发现**（后端服务选的是注册中心里的实例，不是写死 IP）、
绕开 HiMarket 的 Nacos 导入缺陷。HiMarket 侧走「从 Higress 网关导入」（下方验收结果
即以此为准）；只想快速验证时，也可用「+ 创建」MCP Server 直接填上面的 Streamable HTTP
地址，与已验收的 `demo-time-mcp` 是同一做法。

### ✅ 验收结果（2026-11-13，全链路打通）

最终实际走通的链路，与上面的设想有两处不同，以这里为准：

| 环节 | 实际做法 |
|---|---|
| Higress | 控制台「创建 MCP 服务 → 直接路由」，后端服务下拉**直接选 Nacos 发现的 `mini-mcp::1.0.0.mcp-endpoints...`** |
| mcpbridge | **完全没改**（白名单 / nacosGroups 均保持原值） |
| HiMarket | 关联 API 走 **「从 Higress 网关导入」**（不是「+ 创建」、更不是「Nacos 服务发现」） |
| 连接点配置 | 有 `url`、有 `type`，**切到 Streamable HTTP 标签**（SSE 经网关会断） |
| 最后一个卡点 | `curl: (6) Could not resolve host` → 给 `himarket-server` 的 hostAliases 追加 MCP 域名（同 IP 复用已有条目） |

HiChat 实测：勾选该 MCP 后问「几号了」，`get_time` 显示「工具执行完成」，
返回 `2026年11月13日 上午11点20分（北京时间）`。

**结论**：「从网关导入」路径同样绕开了 v0.8.2 的 `stdio` / 空 url / 订阅入口三处缺陷，
且不需要动 `mcpbridge`；Nacos 服务发现经控制台「后端服务」下拉保留。
这是本工作区**第一条同时经过 Nacos + Higress + HiMarket + HiChat 且验收通过**的 MCP 链路。

残留显示问题：回答正文里出现成对的 `<think>…</think>` 原文（答案完整、未截断），
属已知的 Qwen3 reasoning 显示层问题，与 MCP 链路无关，见
`05-运维与排障/03-部署问题排查记录.md` 坑-29 / 坑-30。

### 后续每新增一个 MCP，要做什么

**域名不用建。** `mcpServerExportDomains` 是网关级配置，所有 MCP 共用；
控制台「MCP 接入点域名」是**从已有域名里选**，不是新建。

| 动作 | 是否每次都做 | 说明 |
|---|---|---|
| 域名管理里新建域名 | ❌ 一次性已完成 | 现有 `mcp.example.internal` 共用 |
| 改 `mcpbridge` / 白名单 | ❌ 不用做 | 直接路由不经过白名单机制 |
| `himarket-server` hostAliases | ❌ 一次性已完成 | 同域名解析一次，之后所有 MCP 受益 |
| 新建「服务来源」 | 仅后端地址不同才建 | 同一 Pod 上不同路径的 MCP 可共用一条 |
| MCP 管理 → 创建 MCP 服务 | ✅ 每次 | 服务名、直接路由、后端、Transport=HTTP、路径 |
| HiMarket 关联 API → 从 Higress 网关导入 | ✅ 每次 | 切 Streamable HTTP、同步配置、发布、订阅 |

路径规则：`/mcp-servers/<服务名>`，**服务名决定路径，必须唯一**。
这也意味着多版本 MCP 靠不同服务名区分（如 `mini-mcp-v1` / `mini-mcp-v2`），
仍然不需要新域名。

**什么时候才需要第二个域名**：环境隔离（prod / dev）、内外网隔离、租户隔离。
届时在「域名管理」新增，把它加进 `mcpServerExportDomains` 数组，
并给 `himarket-server` 的 hostAliases 补一条解析 —— 这是唯一会重复的一次性动作。

**下面 8 阶段方案降级为备选**：仅在需要「由 `allowMcpServers` 白名单自动暴露
Nacos 里的 MCP」这种机制时才用，当前 PoC 不需要。

---

> 前提：mini-mcp 已在 `himarket` 命名空间跑通（ClusterIP `<MINI_MCP_IP>:8765`），
> Nacos 里已有 `mini-mcp:1.0.0` 且健康实例 1、工具 3 个，
> HiMarket 里已有直连版产品 `demo-time-mcp` 可用。
>
> **本手册不动 `demo-time-mcp`**，另建一条平行链路做对照，随时可退回。
>
> 执行方式：**纯手工，逐条命令执行**。WorkBuddy 本机没有 kubectl、连不上集群，
> 所有 `kubectl` 命令需在有 kubeconfig 的集群节点上跑，把输出贴回来再决定下一步。
>
> ⚠️ **本手册已全量脱敏**：文中的 `<HIMARKET_GW_IP>`、`<MINI_MCP_IP>`、
> `mcp.example.internal` 等都是替代名，执行前必须换成集群里的真实值。
> 尤其 `-H 'Host: ...'` 必须与 `mcpServerExportDomains` 里的域名**逐字一致**，
> 填占位符会被网关直接拒绝。占位符对照表见 `README-工作空间索引.md` 第十章。

---

## 0. 为什么这条路能成立

对比 HiMarket 的三条导入路径：

| | 从 Nacos 导入（已证伪） | **从网关导入（本手册）** | 自定义直连（已可用） |
|---|---|---|---|
| `sourceType` | `NACOS` | `GATEWAY` | `CUSTOM` |
| `isGateway()` | false | **true** | false |
| 订阅入口 | 被隐藏（Issue #340） | **正常出现** | 正常出现 |
| 连接点 `url` | 空 | **由网关生成，不为空** | 手工填写 |
| `transport` | 恒 `stdio` | 由网关声明 | 手工选 Streamable |
| 是否经过 Nacos 服务发现 | 是 | **是（Higress 订阅 Nacos）** | 否 |
| 是否经过 Higress 鉴权/限流/审计 | 否 | **是** | 否 |

关键点：**Nacos 没有被抛弃**。Higress 的 McpBridge 本身就是 Nacos 的订阅者，
服务发现、IP 变化自动感知、白名单管控这些生产价值全部保留，只是把「谁去读 Nacos」
从 HiMarket 换成了 Higress。HiMarket 改读网关暴露出来的 HTTP 地址，从而绕开
`fillProductConfig()` 那段有缺陷的装配逻辑。

目标链路：

```
HiChat
  ↓ 订阅 + 勾选
HiMarket 产品（网关版，新建）
  ↓ HTTP：http://<网关域名>/mcp-servers/<服务名>/mcp
Higress Gateway  ←── 订阅 ──  Nacos（public / mcp-endpoints）
  ↓ 按实例地址转发              mini-mcp:1.0.0，健康实例 1
mini-mcp Pod（<MINI_MCP_IP>:8765）
```

---

## 1. 改动范围与风险

| 会改 | 不会改 |
|---|---|
| `mcpbridge default` 的 `registries[N]` 里两个字段 | `demo-time-mcp` 产品 |
| HiMarket 新建一个平行产品 | mini-mcp 的 Deployment / Service |
| （可选）`himarket-server` 的 hostAliases | Nacos 里的 MCP 定义 |

风险集中在 `allowMcpServers` / `nacosGroups` 是**整体替换**：漏写原有条目会把别人
正在用的 MCP 一起关掉。所以阶段 0 必须先备份、阶段 2 必须回读确认。

已知不确定点：**服务名带不带 `:1.0.0` 版本后缀**。Nacos 3.x 的 MCP Registry 服务名是
`{name}:{version}`，但 Higress 生成对外路径时用的是 MCP 展示名。两份历史文档写法不一致，
本手册的对策是**白名单两个名字都加、URL 两种都试**，一次做完不用反复 patch。

---

## 阶段 0　摸底（先跑，把输出留着，别急着改）

```bash
# 0.1 mcpbridge 全量配置 —— 备份用，同时数清 company-nacos 的下标
kubectl -n himarket get mcpbridge default -o yaml

# 0.2 只列 registry 名字，确认下标（从 0 数）
kubectl -n himarket get mcpbridge default -o jsonpath='{range .spec.registries[*]}{.name}{"\n"}{end}'

# 0.3 网关 Service 的 ClusterIP 与端口（重点看有没有 80）
kubectl -n himarket get svc higress-gateway -o wide

# 0.4 mini-mcp 还活着
kubectl -n himarket exec deploy/himarket-server -- \
  curl -sS -m 5 http://mini-mcp.himarket.svc.cluster.local:8765/
```

从 0.1 / 0.2 里记下五个值：

| 要记的 | 说明 | 历史值（仅参考，以实际为准） |
|---|---|---|
| `N` | `company-nacos` 在 `spec.registries` 里的下标 | `2` |
| `type` | 该 registry 的类型 | `nacos3` |
| `nacosNamespaceId` | 订阅的命名空间 | `public` |
| 现有 `nacosGroups` | 必须原样保留再追加 | `["DEFAULT_GROUP"]` |
| 现有 `allowMcpServers` | 必须原样保留再追加 | `["native-demo-mcp","openapi-demo-mcp"]` |
| `mcpServerBaseUrl` | 暴露路径前缀 | `/mcp-servers/` |
| `mcpServerExportDomains` | 允许的 Host | `mcp.example.internal` |

从 0.3 记下网关 ClusterIP，后文写作 `<HIMARKET_GW_IP>`。

> 0.4 必须返回 `status: ok` 和 3 个工具。它不通，后面全都不用做。

### 本次实测值（2026-11-13，已脱敏）

四条摸底命令全部通过，确认如下：

| 项 | 实测值 | 影响 |
|---|---|---|
| `company-nacos` 下标 | **2**（共 4 个 registry：2 个 static llm → nacos3 → 1 个 static） | 阶段 2 的 patch 路径用 `/spec/registries/2/`，无需改 |
| `type` | `nacos3` | 走 Nacos 3.x MCP Registry 发现逻辑 |
| `enableMCPServer` | `true` | 网关 MCP 能力已开启，不用改 |
| `mcpServerBaseUrl` | `/mcp-servers/` | 与手册假设一致 |
| `mcpServerExportDomains` | 单个内网域名（真实值见集群配置） | **curl 的 Host 头必须逐字照抄它** |
| `nacosGroups` 现值 | `["DEFAULT_GROUP"]` | 追加 `mcp-endpoints` 时必须保留它 |
| `allowMcpServers` 现值 | `["native-demo-mcp","openapi-demo-mcp"]` | 追加时必须保留这两个 |
| `nacosNamespaceId` | `public` | 与 Nacos 侧一致 |
| `authSecretName` | 非空 | Higress 连 Nacos 带鉴权，说明订阅凭据已就绪 |
| 网关 Service | `LoadBalancer`，port `80:30080/TCP,443:30443/TCP` | **80 端口存在，阶段 5 的端口坑已排除** |
| `EXTERNAL-IP` | `<pending>` | 无 LB 实现；集群内走 ClusterIP:80，外部走 NodePort 30080 |
| mini-mcp | `status: ok`，3 工具，Python 3.7.17 | 服务活着 |

两点补充：

- `vport.default: 8080` **不用管**。MCP 走 `mcpServerBaseUrl` 的路径匹配，挂在标准
  80/443 listener 上，不要去访问 8080 端口。
- `proxies: []` 是正常的，静态上游在 `registries` 里用 `type: static` 表达，不走 proxies。

---

## 阶段 1　备份

```bash
kubectl -n himarket get mcpbridge default -o yaml > ~/mcpbridge-backup-$(date +%Y%m%d-%H%M).yaml
cat ~/mcpbridge-backup-*.yaml | head -40
```

确认文件非空、内容完整再往下走。

---

## 阶段 1.5　零改动探针（建议先做，30 秒）

在动白名单之前，拿**已经在白名单里**的 demo MCP 试一次，用来确认网关的 MCP 机制
本身是活的、Host 头填法是对的。这一步不改任何配置：

```bash
kubectl -n himarket exec deploy/himarket-server -- \
  curl -sS -m 8 -i -X POST "http://<HIMARKET_GW_IP>/mcp-servers/native-demo-mcp/mcp" \
  -H 'Host: <mcpServerExportDomains 里的真实域名>' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```

判读：

| 返回 | 说明 |
|---|---|
| 200 + MCP 响应 | 网关 MCP 机制、Host 头、路径前缀全部正确，接下来只差白名单 → 放心进阶段 2 |
| 404 | demo MCP 只是元数据、没有真实后端，或路径里的服务名口径不同；不能据此否定机制，继续进阶段 2 |
| 403 / Host 不允许 | Host 头填错，先改成 `mcpServerExportDomains` 的真实值 |
| 连接超时 / refused | 网关 ClusterIP 或 80 端口不对，回头查阶段 0 的 0.3 |

> 这一步的价值是把「网关整体坏了」和「只是没把 mini-mcp 加进白名单」区分开。

---

## 阶段 2　改白名单（把 N 换成阶段 0 记下的实际下标）

```bash
kubectl -n himarket patch mcpbridge default --type json -p '[
 {"op":"replace","path":"/spec/registries/2/nacosGroups",
  "value":["DEFAULT_GROUP","mcp-endpoints"]},
 {"op":"replace","path":"/spec/registries/2/allowMcpServers",
  "value":["native-demo-mcp","openapi-demo-mcp","mini-mcp","mini-mcp:1.0.0"]}]'
```

三条注意：

1. `nacosGroups` 必须保留原有分组，只追加 `mcp-endpoints`。
2. `allowMcpServers` 必须带齐阶段 0 读到的所有原有名字；上例的
   `native-demo-mcp`、`openapi-demo-mcp` 只是历史值，以实际为准。
3. 同时写 `mini-mcp` 和 `mini-mcp:1.0.0`，是为了一次性覆盖 Higress 两种可能的
   匹配口径，避免反复试。确认哪个生效后可以删掉另一个。

---

## 阶段 3　回读（不要相信 patch 的返回值）

```bash
kubectl -n himarket get mcpbridge default \
  -o jsonpath='{.spec.registries[2].nacosGroups}{"\n"}{.spec.registries[2].allowMcpServers}{"\n"}'
```

期望两行里分别能看到 `mcp-endpoints` 和 `mini-mcp`。

**历史上出现过 patch 返回成功但值没变的情况**，根因是下标算错、改到了别的 registry。
回读没看到新值就停下来，回阶段 0 重新数下标，不要继续。

等 30 秒让 Higress 重新拉取 Nacos 配置。

---

## 阶段 4　先验证网关能代理，不要急着碰 HiMarket

这一阶段是整条链路的分水岭。网关自己都代理不了，后面配 HiMarket 没有意义。

在 `himarket-server` 容器里发请求（与网关同集群，最可信的测试点）：

```bash
kubectl -n himarket exec deploy/himarket-server -- \
  curl -sS -m 8 -i -X POST "http://<HIMARKET_GW_IP>/mcp-servers/mini-mcp/mcp" \
  -H 'Host: mcp.example.internal' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```

期望：HTTP 200，body 含 `"serverInfo":{"name":"mini-mcp",...}`。

**如果上面这条 404，把路径里的 `mini-mcp` 换成 `mini-mcp:1.0.0` 再跑一次**（冒号在 URL 路径里是合法字符，不用转义）。两种都试，记下哪个通。

| 现象 | 含义 | 下一步 |
|---|---|---|
| `404 route not found` | 网关没认出这个 MCP | 回读阶段 3；确认 `mcpServerBaseUrl` 是 `/mcp-servers/`；换带版本后缀的路径再试 |
| `403` / `Host not allowed` | Host 不在允许列表 | 核对 `mcpServerExportDomains`，或用该域名做 Host |
| `503 no healthy upstream` | 认出了但转发不过去 | Nacos 健康实例数、实例 IP 是否纯 IP、权重是否被设为 0 |
| 连接超时 | 网关到 mini-mcp 网络不通 | 确认 0.4 通过；查 NetworkPolicy |
| 200 但 body 不是 MCP 响应 | Nacos 把该 MCP 标成了 `http-to-mcp`，Higress 按 REST 解析了 | 见「第 10 节 兜底」 |

同时看网关日志辅助判断：

```bash
kubectl -n himarket logs deploy/higress-gateway --tail=100 2>/dev/null | grep -i "mini-mcp\|mcp-servers"
```

> 阶段 4 通过 = Nacos 注册中心 + Higress 代理这一段完全打通，
> 这本身就是本次「全链路」目标里最难的部分。

---

## 阶段 5　HiChat 调用前的前置检查（这一步最容易漏）

HiMarket 从网关导入后，产品里存的 URL 会是类似
`http://mcp.example.internal/mcp-servers/mini-mcp/mcp` 的形式。
而 **HiChat 的请求是 `himarket-server` Pod 发出的**，不是从你的浏览器发的。
这个域名在集群 CoreDNS 里如果不认识，会报 `java.net.ConnectException: null`
（JDK 把 UnresolvedAddressException 包装后的形态），和「连不上」不是一个问题。

```bash
# 5.1 Pod 内能否解析网关域名
kubectl -n himarket exec deploy/himarket-server -- getent hosts mcp.example.internal

# 5.2 网关 Service 有没有 80 端口（HiMarket 拼 URL 不带端口时默认走 80）
kubectl -n himarket get svc higress-gateway -o jsonpath='{.spec.ports[*].port}{"\n"}'

# 5.3 Pod 内直接测 TCP 80
kubectl -n himarket exec deploy/himarket-server -- \
  sh -c 'timeout 3 sh -c "echo > /dev/tcp/<HIMARKET_GW_IP>/80" && echo TCP_OK'
```

三种情况的处理：

| 5.1 / 5.2 / 5.3 结果 | 处理 |
|---|---|
| 全通 | 直接进阶段 6 |
| 域名解析失败 | 给 `himarket-server` 打 `hostAliases`，把 `mcp.example.internal` 指到 `<HIMARKET_GW_IP>`；或改 CoreDNS hosts 段。Java 读 `/etc/hosts`，这条修法有效 |
| 解析通但 80 拒绝 | Service 的 `spec.ports[].port` 是 30080/30443 而非 80/443。历史上已 patch 过，若回退了需重做；或新建 `higress-gateway-http` Service（port 80 → targetPort 80，selector 抄原 Service） |

**本次实测**：5.2 已通过（`80:30080/TCP`），5.3 大概率也通，
因此阶段 5 的重点只剩 **5.1 域名解析**。

> **2026-11-13 实测命中**：5.1 确实失败，`curl: (6) Could not resolve host`，
> 表现为 HiMarket 关联 API 页「工具列表 (0) · 暂无工具」。
> 这是本条链路最后一个卡点，修法就是下面的 hostAliases。

> 注意：Envoy 用 c-ares 直接查 DNS、**不读容器 /etc/hosts**，所以 `hostAliases` 对
> `higress-gateway` 无效，但对 `himarket-server`（Java）有效。两者别搞混。

**先查再改，绝不整体覆盖**（历史上已为模型路由域名打过一条）：

```bash
kubectl -n himarket get deploy himarket-server -o jsonpath='{.spec.template.spec.hostAliases}{"\n"}'
```

按输出分三种情况：

| 输出 | 做法 |
|---|---|
| 空 / `null` | `add /spec/template/spec/hostAliases`，value 为 `[{"ip":"<HIMARKET_GW_IP>","hostnames":["mcp.example.internal"]}]` |
| 已有数组，但 IP 不同 | `add /spec/template/spec/hostAliases/-`，追加一条新条目 |
| **已有数组，且 IP 就是网关 ClusterIP** | **把域名追加到那条条目的 `hostnames` 里**（最优，避免同 IP 重复条目） |

**2026-11-13 实测命中第三种**，实际输出为
`[{"hostnames":["<MODEL_ROUTE_DOMAIN>"],"ip":"<HIMARKET_GW_IP>"}]`，
因此用 `replace` 显式写全两个域名（**必须保留原有的模型域名**，否则会打断已验收的 HiChat 模型链路）：

```bash
kubectl -n himarket patch deploy/himarket-server --type json -p '[
 {"op":"replace","path":"/spec/template/spec/hostAliases/0/hostnames",
  "value":["<MODEL_ROUTE_DOMAIN>","mcp.example.internal"]}]'
```

改完会触发滚动重启，验证**两个域名都能解析**（第二个是保护性检查）：

```bash
kubectl -n himarket rollout status deploy/himarket-server
kubectl -n himarket exec deploy/himarket-server -- getent hosts <MODEL_ROUTE_DOMAIN>
kubectl -n himarket exec deploy/himarket-server -- getent hosts mcp.example.internal
```

---

## 阶段 6　HiMarket 建平行产品（从网关导入）

1. 管理后台 → **产品** → 新建产品，类型选 **MCP Server**，命名 `mini-mcp-gw`（与 `demo-time-mcp` 区分）。
2. 关联 API / 关联 MCP Server 时，来源选 **「从网关导入」**（不是「Nacos 服务发现」）。
3. 列表里找 `mini-mcp`，选中。
4. 进产品详情 → **连接点配置**，逐项确认：
   - `transport` 是 `Streamable HTTP` 或 `SSE`，**不能是 `Stdio`**
   - `url` **非空**，且含 `/mcp-servers/`
5. 点「刷新工具列表」，应出现 `get_time` / `echo` / `add`。
6. **发布**到门户。

> 第 4 步是本手册的验收点：如果这里又出现 `Stdio` + 无 url，说明网关导入路径
> 也复用了同一段装配逻辑，那就不用继续了，直接走第 10 节兜底。

---

## 阶段 7　订阅 + HiChat 验收

1. 用消费者账号在门户订阅 `mini-mcp-gw`，审批通过。
   （网关来源 `isGateway()=true`，订阅入口这次应该正常出现——这本身就是 #340 被绕开的证据。）
2. HiChat 新开对话，**只勾** `mini-mcp-gw`，问「现在几点了？」。
3. 期望模型调用 `get_time` 并返回真实时间；再问「把 hello mcp 回显给我」验证 `echo`。

---

## 阶段 8　对照验证（证明网关真的在链路中间）

两个产品各单独勾一次，问同一句话，然后停掉后端：

```bash
kubectl -n himarket scale deploy/mini-mcp --replicas=0
```

| 观察项 | 直连版 `demo-time-mcp` | 网关版 `mini-mcp-gw` |
|---|---|---|
| 工具列表 | 3 个 | 3 个 |
| Pod 停掉后的报错 | 连接超时 | `503 no healthy upstream` |
| 网关访问日志 | 无记录 | 有请求记录 |

**报错来源不同**就说明网关确实在中间。测完立刻恢复：

```bash
kubectl -n himarket scale deploy/mini-mcp --replicas=1
```

---

## 9. 回滚

只影响网关链路，直连版 `demo-time-mcp` 不受影响：

```bash
# 用备份整体还原
kubectl -n himarket replace -f ~/mcpbridge-backup-YYYYMMDD-HHMM.yaml

# 或只还原白名单（保留其他字段）
kubectl -n himarket patch mcpbridge default --type json -p '[
 {"op":"replace","path":"/spec/registries/2/allowMcpServers",
  "value":["native-demo-mcp","openapi-demo-mcp"]}]'
```

HiMarket 里删掉 `mini-mcp-gw` 产品即可。Nacos 里的 `mini-mcp:1.0.0` 可以保留，不影响任何东西。

---

## 10. 兜底

若阶段 4 就失败（尤其返回 200 但 body 不是 MCP 响应），说明 Nacos 把该 MCP 标成了
`http-to-mcp` 类型，Higress 按 REST 方式解析元数据，这是上一轮复盘里标记过的风险。
此时不要再在 Nacos 侧反复试，按优先级：

1. **自定义直连**（`http://mini-mcp.himarket.svc.cluster.local:8765/mcp`）—— 5 分钟，已验证可用。
2. 在 Nacos MCP 管理里重新建一个干净的 MCP Server，确认「HTTP 转 MCP」开关关闭后再发布。
   （注意：3.2.1 有界面状态 bug，关掉后点发布会被自动重置，需发布后回查确认。）
3. 提 Issue，复现条件见 `03-复盘-Nacos接入MCP全流程.md` 第 9.3 节。

---

## 11. 配套文件

| 文件 | 内容 |
|---|---|
| `03-复盘-Nacos接入MCP全流程.md` | 为什么 Nacos 导入不可用、根因与对照实验 |
| `01-RUNBOOK-从零建MCP.md` | 自定义直连的完整落地流程（已验收可用） |
| `21-mini-mcp.yaml` | mini-mcp 部署清单（ClusterIP） |
| `04-MCP生产化/01-生产级全链路手册.md` | 生产形态：独立命名空间、侧车注册、鉴权限流 |
