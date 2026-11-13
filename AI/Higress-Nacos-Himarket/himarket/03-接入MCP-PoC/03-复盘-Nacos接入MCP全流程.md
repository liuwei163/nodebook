# Nacos 接入 MCP 全流程复盘与 HiMarket 失败分析

> **一句话结论**：Nacos 侧的 MCP 注册、实例健康、工具发现全部验证通过（能从 Nacos 反向调通 mini-mcp 并拉到 3 个工具）；
> 但 HiMarket v0.8.2 的「从 Nacos 服务发现导入」链路存在缺陷——同步出来的连接点配置固定为 `transport=stdio` 且缺少 `url`，
> 导致这条路径在 HiChat 里不可用。**问题在 HiMarket 侧，不在 Nacos 侧。**

---

## 0. 结论先行

| 环节 | 状态 | 判定依据 |
|---|---|---|
| mini-mcp 服务本身 | 通过 | Pod 内 curl 返回 `status: ok`，3 个工具 |
| Nacos 服务注册 | 通过 | 服务列表出现 `mini-mcp:1.0.0`，健康实例 1 |
| Nacos → mini-mcp 协议调用 | 通过 | 「从 MCP 实例导入」成功拉到 `get_time` / `echo` / `add` |
| HiMarket 产品创建（壳） | 通过 | 产品列表出现 `mini-mcp`，类型 MCP Server |
| HiMarket 连接 Nacos 取工具列表 | 部分通过 | 工具列表能显示 3 个，但来自 Nacos 快照 |
| **HiMarket 生成可调用的连接点配置** | **失败** | 只有 `{name,type,protocol}`，无 `url`，`transport` 为 `stdio` |
| HiMarket 订阅机制 | 失败 | 门户固定「无需订阅、开放访问」，但接口又要求有订阅记录 |

**结论：Nacos 侧全部达标，链路断在 HiMarket 的 Nacos 导入适配层。**

---

## 1. 环境与目标

### 1.1 环境清单

| 项 | 值 |
|---|---|
| HiMarket | v0.8.2（2026-10-19 发布） |
| Nacos | v3.2.1 |
| Higress | 集群内网关，ClusterIP `<HIMARKET_GW_IP>`，LoadBalancer 状态 pending |
| MCP Server | `mini-mcp`，自研 Python 单文件服务，镜像 `kubeflow/python:3.7` |
| mini-mcp 地址 | ClusterIP `<MINI_MCP_IP>:8765`，MCP 端点 `/mcp` |
| Nacos 命名空间 | `public` |
| Nacos 分组 | `mcp-endpoints` |
| mcpbridge registry | `spec.registries[2]`，`name: company-nacos` |
| MCP 对外域名 | `mcp.example.internal`，baseUrl 前缀 `/mcp-servers/` |

### 1.2 目标链路

```
HiChat（HiMarket）
   ↓ 订阅 + 勾选
HiMarket 产品（mini-mcp）
   ↓ 从 Nacos 服务发现导入
Nacos 服务注册中心（public / mcp-endpoints）
   ↓ 实例地址
mini-mcp Pod（<MINI_MCP_IP>:8765）
```

### 1.3 为什么走这条路

生产环境的 MCP 不应让 HiMarket 直接填死在某个 Pod IP 上。走注册中心的好处是：服务扩容、滚动更新导致 IP 变化时，不需要改 HiMarket 配置；同时能在注册中心统一管控「哪些 MCP 允许被网关代理出去」。

代价是多了一层元数据同步——本次失败正是发生在这一层。

---

## 2. 前置概念：三个"名字"

这条链路里同一个东西有三个名字，混用会直接导致改配置无效。这是本次踩坑最多的原因。

| 名字 | 出现在哪里 | 本次的值 |
|---|---|---|
| **服务名（含版本）** | Nacos 服务列表、网关白名单 `allowMcpServers` | `mini-mcp:1.0.0` |
| **MCP 展示名** | Nacos MCP 管理列表、HiMarket 产品名 | `mini-mcp` |
| **对外路径名** | 网关路径 `/mcp-servers/<服务名>/...` | 待验证 |

规则：Nacos 3.x 的 MCP Registry 会把服务名拼成 **`{名称}:{版本}`**。所以白名单里写 `mini-mcp` 匹配不上 `mini-mcp:1.0.0`——这也是历史上往 `allowMcpServers` 加 `test` 完全无效的原因（真实服务名是 `test:1.0.0`）。

---

## 3. Nacos 侧完整配置流程（实测可用，可复现）

这一节是本次唯一被完整验证通过的部分，与 HiMarket 成败无关，可独立复用。

### 3.1 入口选择：必须走「MCP 管理」，不是「服务列表 → 创建服务」

左侧菜单有两处看起来都能建：

| 入口 | 存什么 | 是否适用 |
|---|---|---|
| 服务管理 → 服务列表 → 创建服务 | 只有服务名、分组、实例（IP:端口） | 不适用。缺少 MCP 元数据（协议类型、endpoint、工具列表），网关无法识别为 MCP |
| **AI 注册中心 → MCP 管理 → 创建 MCP Server** | 服务信息 + 协议类型 + endpoint + 工具列表 + 版本 | **正确入口** |

判断依据：Nacos 服务列表里出现的 `test:1.0.0` 这种带版本后缀的名字，只能是 MCP 管理入口建的——手工建服务时服务名就是你填什么是什么，不会自动追加版本。

### 3.2 命名空间：只能选 `public`

`public` 不是随便选的，是被 HiMarket 侧的配置锁定的。

`McpBridge` 里 `company-nacos` 这个 registry 的字段是：

```yaml
nacosNamespaceId: public     # 单值字段，只能订阅一个命名空间
nacosGroups:                 # 数组，可以多个
  - DEFAULT_GROUP
```

`nacosNamespaceId` 是**字符串不是数组**，一个 registry 条目只能看一个命名空间。换成其他 UUID 命名的命名空间，会导致 `public` 下所有服务立刻从网关视野消失。

如果确实需要多命名空间并存，正确做法是**新增一个 registry 条目**（另一个 name、同一个 Nacos 地址、不同的 `nacosNamespaceId`），而不是改现有条目。但要注意 `mcpServerBaseUrl` 和 `mcpServerExportDomains` 会在同一域名路径下冲突，需要用不同的 baseUrl 前缀隔离。

> 本次结论：PoC 阶段就守 `public`，不为隔离性付代价。

### 3.3 创建 MCP Server

路径：`AI 注册中心` → `MCP 管理` → 右上角「创建 MCP Server」

| 字段 | 本次填写 | 说明 |
|---|---|---|
| 服务名称 | `mini-mcp` | 小写、连字符，和部署名一致便于对照 |
| 版本 | `1.0.0` | 决定最终服务名 `mini-mcp:1.0.0` |
| 协议类型 | **Streamable** | 见 3.4 |
| 描述 | 自建 MCP：时间查询、文本回显、数值计算 | 会透传到门户展示 |
| 已启用 | 开 | 关掉则不可被探测 |
| HTTP 转 MCP | 关（但会被发布流程重置，见 3.6） | 原生 MCP 不需要转换层 |

### 3.4 协议类型三选一的实际差别

| 类型 | 通信方式 | 需要的配置 | 适用场景 |
|---|---|---|---|
| `Stdio` | 客户端 fork 子进程，走 stdin/stdout | 可执行命令 + 参数 | 本地工具（Claude Desktop、Cursor 插件） |
| `SSE` | HTTP 长连接，`GET /sse` 建流 + `POST /message` 回传 | endpoint URL | 旧式远程 MCP |
| **`Streamable`** | 纯 HTTP POST，无状态 | endpoint URL | **远程 MCP 的标准做法，本次选用** |

选 `Streamable` 的两个理由：

1. 无状态，不需要维持长连接，网关代理时不会因为空闲超时断流。
2. SSE 经网关会失效——SSE 握手返回的 `event: endpoint` 是服务端生成的**绝对路径**（如 `/message?sessionId=xxx`），不含网关前缀。经 Higress 的 `/mcp-servers/xxx/` 路径重写后，客户端会去请求丢了前缀的地址，必然 404。

> mini-mcp 本身两种都实现了，所以直连 ClusterIP 时两种都能工作；但走网关只能用 Streamable。

### 3.5 远程服务配置

这一区块有两个容易误解的地方。

**一、「HTTP 转 MCP」开关**

语义是「你提供一个 REST 接口（配 OpenAPI 规范），我把它包装成 MCP 工具」。mini-mcp 是原生 MCP 服务，不需要这一层，应当关闭。

**但实测这个开关关不掉**：手动关闭后点「发布」，它会被自动重新打开。这是 Nacos 3.2 的界面状态问题，不影响实际探测——因为「从 MCP 实例导入」能拉到标准 MCP 工具定义，说明底层走的是原生 MCP 路径，不是 REST 转换。

**二、「使用已有服务 / 直连新服务」**

- `使用已有服务`：绑定到已经注册在服务列表里的服务（本次应选这个，服务名 `mini-mcp`）
- `直连新服务`：在这里直接新建一个服务条目

本环节未成功绑定（界面两个选项都未选中状态），是后续 HiMarket 拿不到 endpoint 的可疑原因之一。

### 3.6 工具管理：这一步是全流程最有价值的验证点

在 MCP Server 详情页找到「工具管理」，点 **「从 MCP 实例导入」**。

成功结果：

```
get_time    1 参数
echo        1 参数
add         2 参数
```

**这一步的意义远超"填工具列表"**——它让 Nacos 主动发起一次真实的 MCP 调用：

```
Nacos → HTTP POST http://<MINI_MCP_IP>:8765/mcp
      → {"method":"initialize"}  → 拿到 serverInfo
      → {"method":"tools/list"}  → 拿到 3 个工具及 schema
```

所以它同时验证了四件事：网络可达、端点路径正确、MCP 握手成功、响应格式符合规范。**这是整条链路里最底层、最独立的一次验证，任何上层排错都应该先做这一步。**

注意：导入后必须点「保存」。不保存的话工具只存在于当前页面，Nacos 里仍为空。

> 工具列表是**快照，不是实时引用**。mini-mcp 后续增删工具，需要在 Nacos 重新执行一次导入。

### 3.7 发布

点「发布」后回到 MCP 管理列表，卡片应满足：

- 状态：已启用
- 协议标签：`mcp:streamable`
- 工具数：`3 tool`（不是 0）

### 3.8 服务列表验证（一个必踩的坑）

回到 `服务管理 → 服务列表`，如果看不到 `mini-mcp`，**不是创建失败**，是「隐藏空服务」开关开着。

Nacos 的定义：**没有任何实例的服务 = 空服务**，会被过滤。刚创建的 MCP Server 还没有实例时就会被隐藏。

把搜索栏右侧的「隐藏空服务」关掉，再找 `mini-mcp`，确认：

- 服务名显示 `mini-mcp:1.0.0`
- 健康实例数 = 1

健康实例数不是 1 时不要继续往上配，说明 Nacos 到 mini-mcp 的网络或地址有问题。

---

## 4. Nacos 侧成功的硬证据

三处独立证据，互相印证：

| 证据 | 说明 |
|---|---|
| `从 MCP 实例导入` 拉到 3 个工具 | Nacos 完整走通了 MCP 协议调用 |
| 服务列表健康实例 = 1 | Nacos 能持续探测到 mini-mcp |
| HiMarket 工具列表显示 3 个 | HiMarket 能读到 Nacos 侧的工具元数据 |

**结论：Nacos 侧配置完全正确，问题不在这里。**

---

## 5. 失败的环节：HiMarket 连接点配置残缺

### 5.1 现象

产品详情 → 关联 API → 配置详情，显示：

```json
{
  "name": "mini-mcp",
  "type": "remote",
  "protocol": "http"
}
```

三个字段分别是：名字、远端类型、http 协议。**但没有地址**。

同时「连接点配置」标题下方显示 `Stdio`。

这份配置有三个自相矛盾之处：

| 字段 | 值 | 问题 |
|---|---|---|
| `type` | `remote` | 声明是远端服务 |
| `protocol` | `http` | 声明走网络协议 |
| 传输类型标签 | `Stdio` | stdio 要求客户端 fork 本地子进程，与 remote / http 冲突 |
| `url` | 不存在 | 无从知道往哪发请求 |

`Stdio` 在这里是致命的而不是显示错误：如果 HiMarket 真按 stdio 执行，它需要在 `himarket-server` 容器里启动一个子进程，而容器里根本没有 `11-mini_mcp_py2.py` 这个文件。

### 5.2 三组对照实验

为了确认是"配置填错"还是"代码缺陷"，做了三组实验：

| # | 操作 | 预期（若是配置问题） | 实际结果 |
|---|---|---|---|
| 1 | Nacos 协议类型 Streamable → SSE，保存，回 HiMarket 点「同步配置」 | 连接点应变成 SSE | **仍是 stdio，一字未变** |
| 2 | 点「同步配置」让 HiMarket 重新从 Nacos 拉一次 | url 应被补齐 | 工具列表从 0 变 3，**url 仍为空** |
| 3 | 解除关联，重新从 Nacos 导入 | 应生成完整配置 | **仍只有三个字段，无 url** |

实验 1 的结论最硬：**把 Nacos 的 `protocolType` 从 `Streamable` 改成 `SSE`，HiMarket 的输出完全不变**。这说明导入流程根本没读这个字段，值在源端怎么改都不会影响结果。

实验 2 说明了一件重要的事：工具列表和连接点配置走的是**两条不同的数据路径**。

| 数据 | 来源 | 是否正常 |
|---|---|---|
| 工具列表（3 个） | Nacos 的 MCP 定义快照 | 正常 |
| 连接点（地址 + 传输类型） | HiMarket 自己的装配逻辑 | 缺失 |

所以"工具列表能显示 3 个"不能证明链路可用——它只是把 Nacos 里的快照复制过来，并没有真正连过 mini-mcp。

### 5.3 为什么改 Nacos 的三种类型无效

因为出问题的环节在中间：

```
Nacos MCP 定义（protocolType=Streamable）   ← 源端，正确
        ↓
HiMarket 导入代码                            ← 缺陷在这里，不读该字段
        ↓
连接点配置（transport=stdio, url=null）      ← 结果，残缺
```

改源端不会改变接收端的行为。这也是为什么在 Nacos 里反复切换三种协议类型、保存、发布，HiMarket 侧一个字都不变。

---

## 6. 根因分析

### 6.1 根因一：v0.8.2 的修复未覆盖 Nacos 3.x 场景

官方 Release Notes（v0.8.2，Fixes 部分）原文：

> Fixed Nacos MCP imports to expose the correct protocol and client-facing endpoint, preserve HTTPS, and prevent duplicate /sse suffixes.
>
> Existing Nacos MCP products can refresh their connection information by reloading the product configuration.

翻译：

> 修复了 Nacos MCP 导入时暴露正确协议与客户端端点的问题，保留 HTTPS，避免 `/sse` 后缀重复。
>
> 已有的 Nacos MCP 产品，可以通过重新加载产品配置来刷新连接信息。

这条声明与实际表现不符：

| Release Note 声称 | 实测 |
|---|---|
| 导入时暴露正确协议 | 恒为 `stdio` |
| 暴露客户端端点 | `url` 恒为空 |
| 已有产品可通过重新加载刷新 | 解除关联重新导入后仍无 url |

可能原因：修复针对的是 Nacos 2.x 的响应结构，对 Nacos 3.2.1 的 MCP Registry 新格式（`{name}:{version}` + `protocolType` 枚举）没有适配。

### 6.2 根因二：订阅策略被硬编码，Issue #340

https://github.com/higress-group/himarket/issues/340

Issue 标题：`[Bug]: 关联来自Nacos的MCP，固定为无需订阅，开放访问，无法使用订阅？`

维护者在 issue 里贴出了根因代码：

```java
// ProductServiceImpl.fillProductConfig()
product.setSubscribable(
        productRef.getSourceType() != null && productRef.getSourceType().isGateway());
```

逻辑推演：

```
从 Nacos 导入 → sourceType = SourceType.NACOS
             → isGateway() = false
             → subscribable = false
             → 前端 ProductHeader 判定为"开放访问"
             → 隐藏订阅入口
```

这解释了两个此前反复出现的现象：

**现象一：门户显示「无需订阅开发访问」，但 HiChat 报 `API product is not subscribed, not allowed to list tools`。**

门户的展示策略说"不用订阅"，但 HiChat 拉工具列表的接口硬性检查订阅表里有没有记录。开放访问不会自动写订阅记录，于是两边打架。

**现象二：怎么也找不到订阅入口。**

不是入口位置问题，是那个按钮被这段逻辑关掉了。

这条缺陷与 `stdio` 问题在同一个模块，说明 HiMarket v0.8.2 对「Nacos 作为 MCP 来源」的支持整体是半成品状态。

### 6.3 综合结论

| 层面 | 判定 |
|---|---|
| Nacos 侧配置 | 正确，无需修改 |
| HiMarket 的 Nacos 导入适配 | 存在至少两处缺陷（协议/端点装配、订阅策略硬编码） |
| 是否可绕过 | 可。改用网关导入或自定义直连，绕开这段同步逻辑 |
| 是否值得继续在 Nacos 侧试 | 不值得。源端怎么改都不参与同步 |

---

## 7. 排错时间线

| # | 操作 | 结果 | 得到的结论 |
|---|---|---|---|
| 1 | Nacos 创建 MCP Server（Streamable，endpoint `/mcp`） | 成功 | 服务列表出现 `mini-mcp:1.0.0` |
| 2 | HiMarket 建产品，关联 API 选「Nacos 服务发现」 | 成功但配置残缺 | 连接点只有 3 个字段，`transport=stdio` |
| 3 | 点「刷新工具列表」 | 500 `not subscribed, not allowed to list tools` | 权限检查要求订阅记录 |
| 4 | 查门户，显示「无需订阅开放访问」，无订阅入口 | 矛盾 | 展示策略与接口校验不一致 |
| 5 | Nacos 侧执行「从 MCP 实例导入」 | 成功，3 个工具 | **Nacos → mini-mcp 底层完全通** |
| 6 | HiMarket 点「同步配置」 | 工具列表变 3，url 仍空 | 工具快照与连接点走两条路径 |
| 7 | 改 Nacos 协议类型 Streamable → SSE + 同步 | 仍 `stdio` | 导入逻辑不读 `protocolType` |
| 8 | 解除关联，重新从 Nacos 导入 | 仍无 url | 不是时序问题，是代码问题 |
| 9 | 查官方 Release Notes 与 Issues | 找到 v0.8.2 的修复声明 + Issue #340 | 确认为已知缺陷 |
| 10 | 尝试关闭 Nacos 的 HTTP 转 MCP 开关 | 发布后被自动重置 | 界面状态问题，不影响探测 |

关键转折点是第 5 步：它把「底层不通常」这个可能性彻底排除，让后面的排查得以聚焦在 HiMarket 一侧。

---

## 8. 踩坑清单（可复用）

| 坑 | 现象 | 正解 |
|---|---|---|
| 用「服务列表 → 创建服务」建 MCP | 网关识别不出是 MCP，工具列表永远空 | 必须走「MCP 管理 → 创建 MCP Server」 |
| 服务名带版本后缀 | 白名单写 `mini-mcp` 匹配不上 | 写 `mini-mcp:1.0.0` |
| 「隐藏空服务」开关 | 刚建的服务刷新后消失 | 关掉该开关再找 |
| 保护阈值非 0 | 触发保护时返回不健康实例，网关报 `no healthy upstream` | 设为 0 |
| 临时实例 | 手工注册的实例没有心跳，15 秒后变不健康 | 选「否」，用持久实例 |
| 实例 IP 填成完整 URL | 网关拼出无效地址 | IP 字段只放纯 IP，端口单独填 |
| 工具导入后不保存 | 页面显示有工具，Nacos 里是空的 | 必须点「保存」 |
| 工具列表是快照 | mini-mcp 改了工具，Nacos 侧不更新 | 重新执行一次「从 MCP 实例导入」 |
| 工具列表有 3 个就以为链路通了 | 实际只是复制了快照 | 必须验证连接点里有没有 `url` |
| 改 Nacos 协议类型期望修复 HiMarket | 输出一字不变 | 源端不参与同步，别在这上面花时间 |
| SSE 走网关 | 404 | SSE 的 endpoint 是绝对路径，经前缀重写后失效，必须用 Streamable |
| `nacosNamespaceId` 是单值 | 改成新命名空间会让旧命名空间的服务全部消失 | 新增 registry 条目，不要改现有条目 |

---

## 9. 后续可选路径

### 9.1 路径 A：走网关导入（推荐，可验证全链路）

让 Higress 先把 mini-mcp 暴露成 HTTP 地址，HiMarket 从网关列表导入。地址由网关生成，绕开 Nacos 元数据同步这一段有缺陷的代码。

需要：

1. 在 `mcpbridge` 的 `nacosGroups` 加 `mcp-endpoints`
2. 在 `allowMcpServers` 加 `mini-mcp:1.0.0`（注意版本后缀，见第 2 章）
3. 验证网关真能代理（命令见下）
4. HiMarket 解除关联，来源改选「从网关导入」
5. 新建一个平行产品做对照，**不要动已验证可用的 `demo-time-mcp`**

**第 3 步的具体验证**（等 30 秒让 Higress 重新拉取 Nacos 配置）：

```bash
# 网关地址
kubectl -n himarket get svc higress-gateway -o jsonpath='{.spec.clusterIP}{"\n"}'

# 在 himarket-server 容器里测（它和网关同集群，是最可信的测试点）
kubectl -n himarket exec deploy/himarket-server -- \
  curl -sS -m 8 -X POST "http://<网关IP>/mcp-servers/mini-mcp:1.0.0/mcp" \
  -H 'Host: mcp.example.internal' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```

期望返回含 `"serverInfo":{"name":"mini-mcp",...}`。失败时的判断：

| 现象 | 含义 | 下一步 |
|---|---|---|
| `404 route not found` | 网关没认出这个 MCP | 回读 `allowMcpServers`/`nacosGroups`；核对服务名是否带版本后缀；确认 `mcpServerBaseUrl` 是 `/mcp-servers/` |
| `503 no healthy upstream` | 认出了但转不过去 | Nacos 健康实例数、实例 IP 是否纯 IP、权重是否为 0 |
| `200` 但 body 不是 MCP 响应 | 路径对、协议不对 | 去掉版本后缀再试 `/mcp-servers/mini-mcp/mcp` |
| 连接超时 | 网关够不到 ClusterIP | 先在 himarket-server 里直接 curl `http://<MINI_MCP_IP>:8765/` 确认服务活着 |

**第 4 步之后的对照验证**（这是证明"网关真的在中间"的硬证据）：

两个产品各自单独勾选，问同一句话，然后 `kubectl -n himarket scale deploy/mini-mcp --replicas=0`：

| 观察项 | 直连版 | 网关版 |
|---|---|---|
| 工具列表 | 3 个 | 3 个 |
| Pod 停掉后的报错 | 连接超时 | `503 no healthy upstream` |
| 网关访问日志 | 无记录 | 有请求记录 |

**报错来源不同**，就说明网关确实在链路中间。测完记得 `--replicas=1` 恢复。

优点：同时验证 Nacos 注册、Higress 代理、HiMarket 导入三段，符合全链路目标。
风险：如果 Nacos 把该 MCP 标记为 `http-to-mcp` 类型，Higress 可能按 REST 方式解析元数据，导致代理失败。

**回滚**（只影响网关链路，直连版不受影响）：

```bash
kubectl -n himarket patch mcpbridge default --type json -p '[
 {"op":"replace","path":"/spec/registries/2/allowMcpServers",
  "value":["native-demo-mcp","openapi-demo-mcp"]}]'
```

Nacos 里把 `mini-mcp:1.0.0` 下线，HiMarket 里删掉网关版产品即可。

### 9.2 路径 B：自定义直连（最快，5 分钟）

和已验证可用的 `demo-time-mcp` 完全一致：

```
传输方式：Streamable HTTP
地址：http://mini-mcp.himarket.svc.cluster.local:8765/mcp
```

优点：不经过 Nacos、不经过网关，配置天然完整（地址和传输类型都是手填的）。
缺点：Pod IP 变化时需要手工改配置，不具备生产可维护性。

### 9.3 路径 C：提 Issue

本次复现条件干净，值得回报社区：

> 标题：`[Bug]: 从 Nacos 导入 MCP 后连接点 transport 固定为 stdio 且缺少 url，切换 Nacos 协议类型无效`
>
> 环境：Nacos 3.2.1 + HiMarket v0.8.2
>
> 复现：MCP Server 协议类型分别设为 Streamable 与 SSE 各导入一次，HiMarket 连接点配置均为 `{"name":"xxx","type":"remote","protocol":"http"}`，无 `url`、无 `transport`；解除关联重新导入无效。
>
> 关联：与 #340 同属 Nacos 源 MCP 的导入适配问题。

---

## 10. 附录

### A. 常用命令

```bash
# 确认 mcpbridge 结构（记 registries 下标，从 0 数）
kubectl -n himarket get mcpbridge default -o yaml
kubectl -n himarket get mcpbridge default -o jsonpath='{range .spec.registries[*]}{.name}{"\n"}{end}'

# 修改白名单（整体替换，必须带上原有条目）
kubectl -n himarket patch mcpbridge default --type json -p '[
 {"op":"replace","path":"/spec/registries/2/nacosGroups",
  "value":["DEFAULT_GROUP","mcp-endpoints"]},
 {"op":"replace","path":"/spec/registries/2/allowMcpServers",
  "value":["native-demo-mcp","openapi-demo-mcp","mini-mcp:1.0.0"]}]'

# 回读（patch 可能静默失效，不可信任返回值）
kubectl -n himarket get mcpbridge default \
  -o jsonpath='{.spec.registries[2].nacosGroups}{"\n"}{.spec.registries[2].allowMcpServers}{"\n"}'

# 验证 mini-mcp 自身
kubectl -n himarket exec deploy/himarket-server -- \
  curl -sS -m 5 http://mini-mcp.himarket.svc.cluster.local:8765/

# 验证网关是否识别到 MCP
kubectl -n himarket exec deploy/himarket-server -- \
  curl -sS -m 8 -X POST "http://<HIMARKET_GW_IP>/mcp-servers/mini-mcp:1.0.0/mcp" \
  -H 'Host: mcp.example.internal' -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}'
```

### B. 报错对照表

| 返回 / 现象 | 含义 | 处理 |
|---|---|---|
| `404 route not found` | 网关没认出该 MCP | 检查 `allowMcpServers` 与 `nacosGroups`，确认服务名带版本后缀 |
| `503 no healthy upstream` | 认出但上游无可用实例 | Nacos 健康实例数、IP 是否纯 IP、权重是否为 0 |
| 连接超时 | 网关到 ClusterIP 不通 | 网络策略或上游地址错误 |
| `API product is not subscribed, not allowed to list tools` | 缺少订阅记录（展示策略与接口校验不一致，见 #340） | 改用网关或自定义直连 |
| 连接点配置无 `url` | HiMarket 的 Nacos 导入适配缺陷 | 换路径，不要在源端继续试 |

### C. 相关链接

- HiMarket Release v0.8.2：https://github.com/higress-group/himarket/releases
- Issue #340（Nacos 源 MCP 订阅策略写死）：https://github.com/higress-group/himarket/issues/340
- HiMarket MCP Server 管理指南：https://higress.ai/docs/himarket/himarket-mcp-server/

### D. 与本文档配套的其他文件

| 文件 | 内容 |
|---|---|
| `01-RUNBOOK-从零建MCP.md` | 自定义直连方式的完整落地流程（已验收可用） |
| `21-mini-mcp.yaml` | mini-mcp 部署清单（ClusterIP） |
| `11-mini_mcp_py2.py` | MCP 服务端，py2/py3 双兼容，同时支持 Streamable HTTP 与 SSE |
| `12-test-mini-mcp.sh` | 七步 MCP 协议握手自测脚本 |
| `04-MCP生产化/` | 生产级方案（独立命名空间、侧车注册、鉴权限流） |
