# HiMarket 管理员与开发者操作手册

> 环境：移动云 KCS / HiMarket v0.8.2 / 命名空间 `himarket`
> 入口 IP：`<MODEL_GW_IP>`（CLB `elb_ai_platform_dev`），网关端口 30080
> 适用：平台管理员（管资源、发产品、审批）与业务开发者（订阅、调用）

---

## 0. 环境速查

### 0.1 客户端 hosts（内网未做 DNS，必须加）

Windows：`C:\Windows\System32\drivers\etc\hosts`
Linux / macOS：`/etc/hosts`

```
<MODEL_GW_IP>  himarket-admin.example.internal  himarket.example.internal
```

### 0.2 两个入口

env 文件实际路径：`/var/lib/paascontainer/himarket/himarket-backup/himarket-install.env`

| 角色 | 地址 | 默认账号 | 取密码 |
|---|---|---|---|
| 管理员 | `http://himarket-admin.example.internal:30080` | `admin` | `sed -n 's/^ADMIN_PASSWORD=//p' <env文件>` |
| 开发者 | `http://himarket.example.internal:30080` | 门户自行注册 | — |

> ### ⚠️ 密码带双引号，引号是密码的一部分
>
> env 文件里的写法是 `HIGRESS_PASSWORD="<HIGRESS_PASSWORD>"`，而 `install.sh` 取值时**不会剥掉引号**，所以 Console / Nacos / MySQL 里真正的密码就是**含双引号的 15 个字符**。
>
> 实测证据（本环境已验证）：
> - `{"password":"<HIGRESS_PASSWORD>"}` → `Incorrect username or password` ❌
> - `{"password":"\"<HIGRESS_PASSWORD>\""}` → 登录成功 ✅
>
> 因此：
> - 取值用 `sed -n 's/^KEY=//p'`（原样保留），**不要**用 `tr -d '"'` 去引号，去了反而登不上
> - 往任何界面（HiMarket 实例配置、控制台、客户端）粘贴密码时，**连引号一起粘**
> - 反例：手工新建 Higress 实例时填了不带引号的裸密码 → HiMarket 报「服务暂时不可用」，实际是 401

### 0.3 管理员才需要用的内部组件（ClusterIP，需 port-forward）

```bash
# Higress 控制台：查路由、看网关配置
kubectl -n himarket port-forward svc/higress-console 18001:8080
# 浏览器 http://127.0.0.1:18001   账号 admin / HIGRESS_PASSWORD

# Nacos 控制台：查 MCP / Skill / Worker 元数据
kubectl -n himarket port-forward svc/nacos 18080:8080
# 浏览器 http://127.0.0.1:18080/nacos   账号 nacos / NACOS_ADMIN_PASSWORD
```

> ⚠️ 关键区别：浏览器访问用 port-forward；但**在 HiMarket 后台里填的实例地址必须是集群内可达地址**（`*.himarket.svc.cluster.local`），因为请求是 `himarket-server` Pod 发出去的，`127.0.0.1` 在那个 Pod 里指向它自己。

---

## 一、管理员侧操作

管理员的活分两类：**搭架子**（实例、门户、审批策略，一次配好）和**上架产品**（日常重复动作）。

### 1.1 登录

1. 打开 `http://himarket-admin.example.internal:30080`
2. 用户名 `admin`，密码取自 `~/himarket-install.env` 的 `ADMIN_PASSWORD`

初次部署时若还没管理员账号，页面会显示「注册」按钮，填用户名密码后点「初始化」，第一个账号自动成为超级管理员。

**登录后看到的左侧菜单**（v0.8.2 顺序）：
`概览` / `实例管理` / `Portal` / `API Products` / `开发者` / `观测分析` / `系统设置`

### 1.2 导入实例（只在首次做）

HiMarket 本身不存模型和 MCP，它管的是「Higress 网关上的路由」和「Nacos 里的 MCP/Skill/Worker 元数据」，所以必须先让平台认识这两个后端。

#### A. 导入 Higress 网关

路径：**【实例管理】→【网关实例】→【导入网关实例】→ 选【Higress】**

| 字段 | 本环境填什么 |
|---|---|
| Console 地址 | `http://higress-console:8080`（等价写法 `http://higress-console.himarket.svc.cluster.local:8080`） |
| 用户名 | `admin` |
| 密码 | `HIGRESS_PASSWORD` |
| Gateway 地址 | `http://<MODEL_GW_IP>:30080`（⚠️ 见下方说明，这里**不要**填 svc 名） |

点【导入】。成功标志：实例列表出现一条记录，状态为已连接。

> **关于地址写法（重要）**
>
> 1. `himarket-server`、`higress-console`、`nacos`、`higress-gateway` 都在 `himarket` 命名空间，所以**同 ns 内可以只用 svc 短名**，CoreDNS 的 search domain 会补全成 `<ns>.svc.cluster.local`。跨 ns 时短名失效，必须写全 `xxx.other-ns.svc.cluster.local`。
> 2. **端口不能省**。短名默认走 80，而 console 是 8080、nacos 是 8080、gateway 的 Service 端口是 30080（容器端口 80），写成 `http://higress-gateway` 必失败。
> 3. **Gateway 地址会下发给开发者**——它被用来生成门户里展示的调用地址（MCP/Model 没有独立域名时就直接用它）。填 svc 短名会变成 `http://higress-gateway:30080`，开发者在自己电脑上根本解析不了，调用必然失败。所以**只填 Console 用集群内地址，Gateway 填对外 VIP**。
> 4. 排障时 FQDN 更清晰（日志里一眼看出指向哪个 ns 的哪个服务），成本为零，建议 Console/Nacos 直接用 FQDN 写法。

#### B. 导入 Nacos

路径：**【实例管理】→【Nacos 实例】→【导入】**

| 字段 | 本环境填什么 |
|---|---|
| 实例名称 | `default-nacos`（初始化钩子已建，直接编辑即可） |
| 服务器地址 | `http://nacos.himarket.svc.cluster.local:8848` — **8848 是 Nacos OpenAPI 端口**，HiMarket 后端读 MCP/Skill/Worker 配置走它 |
| 展示地址 | **先留空**，原因见下 |
| 用户名 / 密码 | `nacos` / `NACOS_ADMIN_PASSWORD` |
| Access Key / Secret Key | 留空（Nacos 用用户名密码鉴权时不需要 AK/SK） |
| 命名空间 | `public`（默认） |

> **8848 还是 8080？** 别混：
> - **8848** = Nacos OpenAPI / 配置中心端口，HiMarket 后端调它，所以「服务器地址」填 8848
> - **8080** = Nacos 3.x 独立 Web 控制台，只在你要用浏览器看页面时用（port-forward 那段）
>
> 判断填对没有：点【API Products】→【导入 Skills】，能扫出 Nacos 里的 Skill 列表 = 通。扫不出来再把端口换成 8080 试一次。
>
> **「展示地址」为什么建议留空**：这一栏的官方定义是「配置后，开发者在门户中 Skill/Worker 的**下装命令**将使用此地址替代服务器地址」，用于服务器地址是内网、需要通过公网域名或 IP 对外访问的场景。
> 本环境 Nacos 是 ClusterIP，**集群外根本连不上**。如果这里填了内网 svc 地址，门户生成给开发者的 CLI 命令（`npx ... --nacos-host ...`）在他自己电脑上必然解析失败。
> 结论：
> - 开发者用**门户网页下载 ZIP** → 走 himarket-server 代理，不需要直连 Nacos → 留空即可
> - 要支持**CLI 在线安装** → 先用 Higress Ingress 或 NodePort 把 Nacos 8848 暴露到集群外，再把对外地址（如 `http://<MODEL_GW_IP>:<port>`）填到这里

#### E. 初始数据说明：为什么有的 tab 有 100+ 条、有的是空的

初始化钩子只往市场里灌了 **Skill 和 Worker**，两者加起来正好 360 条（本环境实测 174 Skills + 186 Workers），状态全部「已发布」。所以：

| Tab | 初始条数 | 说明 |
|---|---|---|
| Agent Skill | 100+ | 初始化从 Nacos 同步，通 |
| Worker | 100+ | 同上，通 |
| Model API | 0 | **正常**，模型不会自动发现，必须手工建产品 + Link API |
| MCP Server | 0 | **正常**，同上 |
| Agent API | 0 | **正常**，同上 |
| REST API | 0 | **正常**，同上 |

**结论：Nacos 连通性已由 Skill/Worker 的数据量证明；Higress 连通性尚未被证明**，因为没有任何 Model/MCP 产品去触发过对网关的调用。

验证 Higress 的两种方式：

1. **建一个 MCP Server 类型产品 →【Link API】→ 来源选 Higress**
   - 弹窗正常打开、列表为空 → 连通，只是网关里没有 MCP 服务
   - 弹窗报错 / 转圈超时 → 连通性问题，查 Console 地址与密码
2. **直接看控制台**：`kubectl -n himarket port-forward svc/higress-console 18001:8080` → 看「AI 路由」「MCP 服务」列表里到底有没有东西

> 按钮位置别找错：Agent Skill 页是右上角【导入 ▾】**下拉**里的「导入 Skills」；Worker 页是【从 Nacos 导入】。

#### C. 验证实例是否真的连通（三层，逐层加严）

保存成功 ≠ 连通。HiMarket 保存实例时不一定探活，所以必须做功能级验证。

**L1 页面层（10 秒）**

- 【实例管理】→【网关】：列表里有那条 Higress 记录，无红色报错标记
- 【实例管理】→【Nacos】：`default-nacos` 带「默认」标记，状态正常

这一层只能证明「配置存下来了」，不能证明通。

**L2 功能层（最关键，1 分钟）**

| 验证对象 | 操作路径 | 通过标准 |
|---|---|---|
| **Nacos** | 【API Products】→ 右上角【导入 Skills】→ 选 `default-nacos` | 弹出列表能扫出 Skill（本环境初始化已导入 174 个），不是空列表、不报错 |
| **Nacos（间接）** | 直接看【API Products】列表总数 | 有大量现成产品（初始化导入了 360 个）= 当初的 Nacos 同步成功 |
| **Higress** | 建/选一个 MCP 类型产品 →【Link API】→ 来源选 `Higress` | 列表里能看到网关上的 MCP 服务 |
| **Higress（Model）** | 建/选一个 Model API 产品 →【Link API】 | 列表里能看到 Higress 上的 AI 路由 |

列表为空 = 实例没通，或网关里确实没资源。两者要分开判断：去 Higress 控制台 `port-forward` 看路由是否存在。

**L3 服务端日志（兜底）**

```bash
kubectl -n himarket logs deploy/himarket-server --tail=100 | grep -iE "nacos|higress|connect|refused|timeout|401|403"
```

- 干净无报错 = 调用链正常
- 出现 `Connection refused` / `timeout` → 地址或端口错（检查 8848、8080、30080）
- 出现 `401/403` → 账号密码错，或 Nacos 开了鉴权但没填 AK/SK

**L4 端到端（最终确认）**

门户首页能打开 → 注册/审批一个开发者 → 能订阅产品 → HiChat 对话成功 / curl 返回 200。到这一步才算整条链路通。

#### D. 门户侧确认（做完 A/B 之后）

【门户】页面卡片上能直接读到的状态（本环境 `demo`）：

| 卡片字段 | 含义 | 当前值 |
|---|---|---|
| 访问地址 | 默认域名 `portal-xxx.api.portal.local` | 需自行解析；单门户时直接访问 `himarket.example.internal` 会回落到默认门户 |
| 账号登录 | 是否允许用户名密码登录 | 支持 |
| 开发者审批 | 新注册开发者要不要人工批 | **手动** ← 自己测的时候记得先去审批，或改成自动 |
| 订阅审批 | 订阅产品要不要人工批 | 自动 |

点卡片进 Products 页，已发布产品数 > 0 = 初始化发布链路正常。

### 1.3 创建门户（只在首次做）

门户 = 面向开发者的店面，多租户靠域名区分。

路径：**【Portal】→【创建 Portal】**

1. 填门户名称（如 `AI 能力市场`）、描述
2. 点【确定】，卡片出现在列表
3. 点卡片进入配置页，逐页配：

| 标签页 | 必做动作 |
|---|---|
| **Overview** | 看统计：已发布产品数、注册开发者数 |
| **Products** | 已上架产品清单，可下架 |
| **Developers** | 开发者审批、查看其 Consumer 与订阅 |
| **Security** | ★ 两个审批开关 + 登录方式（详见 1.4） |
| **Domain** | 绑定访问域名（本环境 `himarket.example.internal` 已绑） |

**Domain 注意事项**：系统会自动分配一个 `portal-xxxx.api.portal.local` 的默认域名，这个域名必须自己做 DNS/hosts 才能访问。生产上建议绑真实域名。

### 1.4 配置审批策略（★ 最容易卡住开发者的地方）

路径：**【Portal】→ 点门户卡片 →【Security】**

两个开关，决定开发者能不能自助跑起来：

| 开关 | 选项 | 建议 |
|---|---|---|
| 开发者注册审批 | 自动通过 / 手动审批 | **手动审批**（企业内部，可控） |
| API Product 订阅审批 | 自动通过 / 手动审批 | POC 阶段选**自动通过**，减少来回 |

> 默认是手动审批。这就是新注册开发者登录时报 `Invalid request: Your account is pending approval` 的原因——不是 bug。
> 内部试用期想省事，两个都设自动，开发者注册完立刻能用。

同一页还能配 **OIDC 登录**（对接企业 SSO，见官方 `himarket-oidc-integration`），启用后可用企业账号直接登录门户。

### 1.5 审批开发者（日常高频动作）

路径：**【Portal】→ 门户卡片 →【Developers】**

- 列表里 `待审批 / Pending` 的账号 → 点【审批通过】/【启用】
- 审批通过后，开发者才能登录门户
- 同一页可查看该开发者的 Consumer 列表和订阅记录

> 提示：新装环境想让某人马上能用，直接在后台建一个已激活的开发者账号更快，省掉「注册 → 等审批」这一轮。

### 1.6 上架产品：先判断是哪种类型

路径统一是 **【API Products】→【创建 API Product】**，但**类型决定了后面配什么**，这是最容易走错的地方：

| 产品类型 | 适合什么 | 创建后要走哪条配置路径 |
|---|---|---|
| **Model API** | LLM 服务（Higress 上的 AI 路由） | Link API 关联 AI 路由 + 填模型参数 |
| **MCP Server** | 工具服务、API 转 MCP | MCP 配置 注册/导入 + 刷新工具列表 |
| **Agent API** | Agent 应用（AgentScope 等） | Link API 关联网关 Agent 应用 |
| **Skill** | 技能包（ZIP） | 上传 Skill 包，**不需要 Link API** |
| **Worker** | 可装载 Skill 的执行单元 | 上传 Worker 包 + 版本管理 |

> **Model API 有前置条件**：必须先在 Higress 里有一条 AI 路由，否则 Link API 的列表永远是空的。完整的六步流程（含逐字段填法和验收命令）见**第六章**，本节只讲通用表单。

### 1.7 创建产品（通用表单）

**【API Products】→【创建 API Product】**，填：

- **产品名称**：给开发者看的名字，如 `通义千问-Plus`
- **产品类型**：按 1.6 选
- **产品描述**：一句话说清用途
- **产品类别**：分类筛选用，可自定义
- **产品图标**：URL 或上传本地文件

点【确定】→ 进入详情页，状态为 **「待配置」**。

> Model API 额外要填：模型名称（Model）、Max Tokens、Temperature、是否支持联网搜索。**这几项不能空**，HiChat 前台调试靠它，缺了会调不通。

### 1.8 关联 API（MCP / Model / Agent 必做，Skill/Worker 跳过）

详情页 →**【Link API】** 标签：

1. 选资源类型：`MCP Server` / `Model API` / `Agent API`
2. 选来源：`Higress` 或 `Nacos`
3. 从列表里挑具体资源（Model 选 AI 路由；MCP 选 MCP 服务）
4. 点【关联】

**状态流转**：`待配置` →（关联成功）→ **`待发布`**

如果列表是空的，回到 1.2 检查实例是否导入成功、网关里是否真有你想要的那条路由。

MCP 的额外动作（详情页 →**【MCP 配置】**）：

- 【刷新工具列表】：实际去连 MCP Server 拉 tool 定义，能拉到才算通
- 【编辑工具配置】：改工具名、描述、参数、请求模板
- 【编辑服务介绍】：Markdown，写清工具清单和用法
- 【部署沙箱】：需要 HiMarket 托管运行时才用（选沙箱实例、协议、鉴权、规格）

### 1.9 写使用指南

详情页 →**【Usage Guide】** 标签，Markdown 编辑，建议必写四块：

1. 功能与适用场景
2. 认证方式（怎么拿凭证）
3. 请求 / 响应示例（开发者直接复制）
4. 错误码与限制（限流、配额）

支持实时预览，点【保存】。

> 这一页就是开发者看到的接入文档。写得越具体，后面被问的次数越少。

### 1.10 发布到门户

详情页 → 确认状态是 **「待发布」** →**【发布到门户】** → 勾选目标门户（可多选）→【发布】。

发布后立刻出现在门户对应市场：Model 进【模型】、MCP 进【MCP】、Skill 进【Skills】、Worker 进【Worker】。

### 1.11 版本与下架

- **Skill**：详情页【Skill Package】→ 版本列表 →【发布】（提交审核）/【设为最新】/【上线】【下线】/【强制发布】（跳过审核）
- **Worker**：详情页【版本】→【发布】填版本号（如 `1.0.0`）/【设为最新】/【上线】【下线】/【删除草稿】
- **下架产品**：Portal → Products → 移除；或产品详情里下线版本

版本状态：`草稿` → `审核中` → `上线` → `下线`。同一时间只能有一个草稿版本。

### 1.12 批量导入（省事用）

- **Skills / Workers**：【API Products】→【导入 Skills】/【从 Nacos 导入】→ 选 Nacos 实例 → 选命名空间 → 系统扫描并建产品（同名不会重复导入）
- **MCP**：`MCP 供应商导入` 页 → 选 ModelScope / MCP Registry → 搜索勾选 → 批量导入（导入后是草稿态，要手动发）

### 1.13 运营与观测

- **观测分析**：调用趋势、热门产品、异常流量，可按产品或开发者维度看
- **订阅管理**：Portal → Developers → 看某人的订阅；开手动审批时在这里批订阅
- **限流与安全**：产品级可配鉴权、限流、IP 白名单；网关侧策略在 Higress 控制台配

---

## 二、开发者侧操作

开发者只需要记住一件事：**Developer 是「人」，Consumer 是「钥匙」**，一把钥匙可以开多把锁（订阅多个产品），一个开发者可以有多把钥匙（dev/test/prod）。

### 2.1 注册

1. 打开 `http://himarket.example.internal:30080`
2. 点【注册】，填用户名 + 密码，提交
3. 若门户开了手动审批 → 提示待审批，**此时登录会报 `Your account is pending approval`**
4. 找管理员审批（或等自动通过），然后登录

> 每个门户的账号独立，换门户要重新注册。

### 2.2 浏览市场

登录后左侧/顶部导航：`模型` / `MCP` / `智能体` / `Skills` / `Worker` / `HiChat` / `HiCoding`。

- 列表可按类别筛选、搜索
- 点卡片进详情：功能说明、使用指南、工具列表、文件树、版本历史、调用示例

### 2.3 创建 Consumer（拿凭证）

**右上角头像 →【消费者管理】→【新增消费者】**

- **消费者名称**：`my-app-prod`（按环境区分）
- **描述**：生产环境应用

点【提交】→ 系统生成 **API Key / Secret**，抄下来保存。

> 注册时系统会自动分配一个默认 Consumer。HiChat 用的就是这个默认 Consumer，可在【消费者管理】里改默认。

### 2.4 订阅产品

1. 进产品详情页 → 点【订阅】
2. 选一个 Consumer
3. 点【确定订阅】

状态看 **消费者管理 → 订阅列表**。若门户开了手动订阅审批，要等管理员批。

> 没订阅 = 调不通，这是新手最常见的问题。

### 2.5 发起调用

#### 模型（Model API）

OpenAI 兼容形态，`Authorization: Bearer <Consumer 的 API Key>`：

```bash
curl http://<MODEL_GW_IP>:30080/v1/chat/completions \
  -H "Host: <该模型路由域名>" \
  -H "Authorization: Bearer <API Key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"<模型名>","messages":[{"role":"user","content":"你好"}]}'
```

`baseUrl`、`model`、`Host` 以产品详情页的 **Usage Guide** 为准，不要凭猜。

#### MCP Server

- 在 **HiChat** 里选模型 + 勾 MCP，直接对话验证（最快）
- 或在本地 MCP 客户端（Claude Code / Cursor 等）配置服务地址 + `Authorization: Bearer <API Key>`，具体 endpoint 从详情页复制
- 未订阅时可点【快速订阅】，用默认 Consumer 一键订阅

#### Agent API

同模型调用形态，路径与参数看产品详情页示例。

#### Skill / Worker（不是 API，是文件包）

1. 详情页 →【订阅】
2. 选版本 →【下载】得到 ZIP
3. 或复制【CLI 安装】命令直接装：

```bash
himarket install worker <worker-name>
himarket install worker <worker-name> --version 1.0.0
```

Skill 的 CLI 走 npx 拉 Nacos 上的包，命令里带 nacos-host/port/namespace，详情页会自动生成，复制即可。

### 2.6 HiChat / HiCoding（不用写代码就能验证）

**HiChat**（门户 →【HiChat】）：

1. 选一个已订阅的模型
2. 需要工具时勾选已订阅的 MCP Server
3. 直接对话；模型会按需自动调工具
4. 支持多模型对比、联网问答（需网关侧配了联网搜索）

**HiCoding**（门户 →【HiCoding】）：在线 AI 编程，带沙箱环境，可选 CLI Provider（Claude Code / Qwen Code 等）、注入订阅的 MCP 与 Skill、选运行时（本地 / K8s 沙箱），能看文件变更和终端。

---

## 三、30 分钟走通一遍（建议照这个脚本验收）

| # | 谁 | 动作 | 预期 |
|---|---|---|---|
| 1 | 管理员 | 登录后台，确认实例列表 Higress/Nacos 都是已连接 | 无红色告警 |
| 2 | 管理员 | Portal → 该门户 → Security → 两个审批都设**自动** | 保存成功 |
| 3 | 管理员 | API Products 里挑一个现成产品（初始化已导入 360 个），确认状态是「已发布」 | 门户能看到 |
| 4 | 开发者 | 门户注册 `test01` | 直接能登录（自动审批） |
| 5 | 开发者 | 头像 → 消费者管理 → 新增 `test01-dev` | 拿到 API Key |
| 6 | 开发者 | 订阅一个模型产品，选 `test01-dev` | 订阅列表显示已生效 |
| 7 | 开发者 | HiChat 选该模型发一句「你好」 | 有回复 |
| 8 | 开发者 | 用 curl 直调一次，带 API Key | 200 + JSON |
| 9 | 管理员 | 观测分析 → 看调用记录 | 能看到刚才这次调用 |

第 9 步能看到调用记录 = 整条链路（门户 → 鉴权 → 网关 → 模型）都通了。

---

## 四、报错对照

| 现象 | 原因 | 处理 |
|---|---|---|
| 登录报 `account is pending approval` | 门户开了手动审批 | 后台 Developers 审批，或 Security 改自动 |
| Link API 列表是空的 | 实例未导入 / 网关无该路由 | 回 1.2 检查实例连通性 |
| 产品调 401 | 没订阅，或 Key 不对 | 确认订阅生效，Key 用 Consumer 的 |
| 产品调 404 | 路径或 Host 不对 | 按 Usage Guide 的 baseUrl/Host 复制 |
| HiChat 提示模型不可用 | 模型未订阅 / 模型参数没填 | 订阅 + 补 Model、Max Tokens、Temperature |
| Skill 上传失败 | ZIP > 10MB、缺 `SKILL.md`、name/description 为空 | 按格式要求重打包 |
| Worker 发布灰掉 | 没有「上线」版本 | 先发布版本并上线 |
| 两个域名返回同一页面 | 命中 chart 兜底 Ingress | `kubectl get ingress -n himarket`，补 Host 路由 |

---

## 五、角色分工一句话版

| 事项 | 管理员 | 开发者 |
|---|---|---|
| 导入网关 / Nacos | ✅ | — |
| 建门户、绑域名、配审批 | ✅ | — |
| 审批开发者与订阅 | ✅ | 提交申请 |
| 建产品、关联 API、写指南、发布 | ✅ | 浏览 |
| 建 Consumer、拿 Key | 可代建 | ✅ |
| 订阅、调用、HiChat/HiCoding | 可旁观 | ✅ |
| 观测、限流、计费 | ✅ | 看自己的用量 |

---

## 六、专题：添加 Model API（从模型服务到可调用）

> **本章与《HiMarket-跨集群接入模型-全流程配置手册.md》内容有重叠**，定位不同：
> 本章是"界面怎么点"的操作视角，保留了当时排查的原始推演过程（含 `openaiCustomUrl` 必须是完整端点、
> `route_name` 定位抢路由、HiChat `ConnectException` 的 DNS 根因）；
> 那份是"六阶段 + 七级验收"的结构化流程，按顺序执行更快。**第一次做建议照那份走，卡住了回本章查推演。**

前提：模型服务已存在（跨集群，经同一 LB 的 32582 端口暴露），Higress、Nacos 两个实例均已连通（1.2 节）。

### 6.1 全景：四段链路，三个掉坑点

| 段 | 在哪做 | 产出 | 不做会怎样 |
|---|---|---|---|
| ① 模型服务 | 你自己的集群 | `:32582/v1/chat/completions` | 后面全是空转 |
| ② AI 路由 | Higress 控制台 | 一条指向该服务的路由 | HiMarket 的 Link API 列表永远空 |
| ③ 产品包装 | HiMarket 后台 | Model API 产品（待配置→已发布） | 门户里看不到 |
| ④ 订阅调用 | 开发者门户 | Consumer API Key | 调用 401 |

三个最高频的坑：**上游填了域名**（Pod 解析不了）、**超时没改**（长回答必断）、**模型名三处不一致**（400 model not found）。

### 6.2 第 0 步：确认模型服务本身可用

在集群任意节点执行：

```bash
curl -s -m 8 http://<MODEL_GW_IP>:32582/v1/models | head -c 400
```

| 返回 | 判断 |
|---|---|
| `{"object":"list","data":[{"id":"...","object":"model"}]}` | ✅ 记下 `id`，这是**上游模型名**，后面三处都要原样用它 |
| 404 | 路径不是 OpenAI 形态，试 `/api/tags`（Ollama 原生）或看服务文档 |
| 000 / 超时 | 端口没起或 LB 没转发，先解决这一层 |

再确认能真正推理（健康检查通不代表能推理）：

```bash
curl -s -m 60 http://<MODEL_GW_IP>:32582/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<上一步的 id>","messages":[{"role":"user","content":"你好"}],"max_tokens":20}'
```

返回 `choices` = 可用。若服务要求鉴权，把 `Bearer sk-xxx` 记下来，第 1 步要填。

**判断上游到底要不要 Key**（决定后面怎么填）：

```bash
# 不带任何认证头，看返回什么
curl -s -m 10 -o /dev/null -w '%{http_code}\n' http://<MODEL_GW_IP>:32582/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<模型 id>","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
```

| 状态码 | 结论 | 第 1 步的 API Key 字段 |
|---|---|---|
| 200 | 不校验 | 填 `sk-none` 占位即可 |
| 401 / 403 | 校验 Key | 填真实 key，**由网关代填，不要发给开发者** |
| 000 | 服务根本没起 | 先解决服务，别往下走 |

带 Key 再确认一次能通：

```bash
curl -s -m 60 http://<MODEL_GW_IP>:32582/v1/chat/completions \
  -H 'Authorization: Bearer <自建模型的 key>' \
  -H 'Content-Type: application/json' \
  -d '{"model":"<模型 id>","messages":[{"role":"user","content":"你好"}],"max_tokens":20}'
```

### 6.3 第 1 步：在 Higress 建 AI 路由（最关键）

**6.3.0 先分清两个 Key（这是自建模型接入的核心）**

```
开发者 ──[ Consumer Key ]──> Higress 网关 ──[ 模型 Key ]──> 自建模型服务
```

| | Consumer Key | 模型 Key |
|---|---|---|
| 谁生成 | HiMarket 门户，订阅时自动发 | 你自建服务时设定的 |
| 谁持有 | 开发者（在消费者管理里可见） | 只有网关知道，写在 AI 路由里 |
| 作用 | 让网关认出是谁、有没有订阅、算配额 | 让自建模型服务认网关 |
| 会变吗 | 可随时吊销、重建 | 固定 |
| 泄露后果 | 吊销重发即可 | 别人能直接刷你的卡/GPU |

接入的全部意义就在这一行：**开发者永远拿不到模型 Key**，他只能拿到 Consumer Key；网关做一次替换再转发。所以模型 Key 只填在 AI 路由里，不要写进 Usage Guide、不要贴到群里。

```bash
kubectl -n himarket port-forward svc/higress-console 18001:8080
# 浏览器 http://127.0.0.1:18001
# 账号 admin / 密码 "<HIGRESS_PASSWORD>"（含双引号，见 0.2）
```

**6.3.1 先建服务来源（跨集群必须走这条）**

左侧【服务来源】→【创建服务来源】→ 类型选**固定地址**（部分版本叫「DNS 域名」/「静态地址」）→ 地址 `<MODEL_GW_IP>:32582`，协议 HTTP。

不要填 `model-gw.example.internal`：它只在你本机 hosts 里，`higress-gateway` 的 Pod 走 CoreDNS，解析不到。而 HTTP 不涉及 SNI，用 IP 完全等价。

> **「服务端口」固定 80 是设计，不是故障**：固定地址类型的服务来源，地址栏本身支持多条 `IP:Port`，所以需要一个**逻辑服务端口**来避免端口随后端地址动态变化。Higress 把这个逻辑端口恒定为 80，**不随后端地址里的端口变化**，控制台里也就不可编辑。
>
> 原话见 [higress#1682](https://github.com/alibaba/higress/issues/1682)：「所有固定地址服务的端口固定是 80，不随配置的后端地址中的端口变化」。
>
> 结论：服务列表里「服务端口 80 + 地址 <MODEL_GW_IP>:30081」是**正常显示**，真实端口由地址栏里的 `:30081` 决定，请求最终打在 30081 上。不要试图把它改成 30081，也**不要因为看到 80 就去重新配置**。
>
> ⚠️ 另有一个控制台渲染问题：编辑已有来源时，「服务地址」textarea 可能不回显已有值（显示为空并标红）。此时**不要点确定**，否则会把已配好的地址清掉。

**6.3.2 建 AI 路由**

左侧【AI 网关】/【AI 路由管理】→【创建 AI 路由】。若没有独立菜单，在【路由配置】页顶部切「AI 路由」标签；两种入口都没有，说明 console 版本偏老，告诉我，改用 WasmPlugin 方式配。

| 字段 | 本环境填什么 | 说明 |
|---|---|---|
| 路由名称 | `deepseek-32b` | 后台 Link API 列表显示的就是它 |
| 域名 | `model.example.internal` | 不能空。实际可能是 `himarket.model.example.internal` 这种自动生成值，**以列表里显示的为准**，测试时 `Host` 头必须与它逐字一致 |
| 路径 | `/v1`（必填） | 控制台把它当**基地址前缀**，请求进来后按 OpenAI 端点自动补齐，所以 `/v1` 就能拼出 `/v1/chat/completions`。部分版本需要写全 `/v1/chat/completions`——**以实测为准**，见 6.3.3 |
| 上游服务 | 选上一步的固定地址 | 不要选 K8s 服务，模型不在本集群 |
| 协议 | `HTTP` | 内网不走 TLS，别选 HTTPS |
| Provider / 服务协议 | `OpenAI 兼容`（有 DeepSeek 选项就选 DeepSeek） | 自建服务基本都是 OpenAI 兼容 |
| 模型名称 / 模型映射 | 先留空（= 透传） | 留空时前端传什么就发给上游什么；要防乱填就配 `*` → 真实 id |
| API Key（模型 Key） | 上游校验时填真实 key；不校验填 `sk-none` | 网关会用它**自动替换**客户端的 `Authorization` 头 |
| 超时 | `300000`（ms） | **默认十几秒，长回答会被切断**，仅次于 401 的高频故障 |

保存后状态应为「已启用」。

> 若控制台把认证拆成独立项（如「上游认证」「凭证」），填的还是同一个模型 Key，效果一致：网关代填 `Authorization: Bearer <model key>`。

**6.3.3 网关侧直接验收（先别碰 HiMarket）**

```bash
curl -s -m 60 http://<MODEL_GW_IP>:30080/v1/chat/completions \
  -H 'Host: model.example.internal' \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-32b","messages":[{"role":"user","content":"你好"}],"max_tokens":20}'
```

返回 `choices` → 网关这段彻底通了。**这一步不通过就别往下走**，否则后面的报错会把你引向错误方向。

> **⚠️ `-s` 会把失败伪装成「什么都没发生」**：`curl -s` 会吞掉超时、连接失败、TLS 错误的提示，命令直接静默退出，**输出为空**。空输出 ≠ 通，也 ≠ 4xx，它最常见的意思是「超时了」（32B 模型冷启动首 token 可能超过 60s，退出码 28）。
>
> 所以验收时一定要带上状态码和耗时，别用裸 `-s`：
>
> ```bash
> curl -sS -o /tmp/r.json -w 'code=%{http_code} time=%{time_total}s\n' -m 300 \
>   http://<MODEL_GW_IP>:30080/v1/chat/completions \
>   -H 'Host: himarket.model.example.internal' -H 'Content-Type: application/json' \
>   -d '{"model":"DeepSeek-R1-Distill-Qwen-32B","messages":[{"role":"user","content":"你好"}],"max_tokens":20}'
> cat /tmp/r.json; echo
> ```
>
> `-sS` 只在失败时打印错误，`-o` 把 body 落盘避免和状态码混在一起，`-w` 强制打印状态码——**有 code 才算有结论**。

**这条命令在哪里执行？三个位置，证明的东西不同：**

| 执行位置 | 命令前缀 | 证明了什么 | 结论强度 |
|---|---|---|---|
| 集群任一节点（你现在这里） | 直接 curl | 节点 → LB → 网关 → 上游 整条链路通 | 强，能定位网关和上游 |
| Windows 本机 | `curl.exe`（需 hosts 有 `himarket.model.example.internal`） | 办公网 → LB 通 | 弱，只证网络，不代表 Pod 能通 |
| **`higress-gateway` Pod 内**（最贴近真实） | `kubectl -n himarket exec deploy/higress-gateway -- curl ...` | **真实调用路径**：Pod 网段能不能到 LB | 最强，出问题时必须是这一层 |

真正的线上流量从 `higress-gateway` 的 Pod 发出，源地址属于 Pod CIDR。节点能通而 Pod 不通，是跨集群场景最典型的故障（安全组只放通节点网段）。所以节点上失败要看 Pod，节点上成功也要用 Pod 复核一次：

```bash
kubectl -n himarket exec deploy/higress-gateway -- \
  curl -sS -m 60 -o /dev/null -w 'pod->lb code=%{http_code}\n' \
  http://<MODEL_GW_IP>:30081/v1/models
```

注意这条命令**故意不带 `Authorization` 头**：自建模型要 key 的情况下它还能返回 `choices`，才说明网关真的把模型 Key 代填进去了——这是验证「Key 是否配对」最有效的一招，比进后台翻配置快。

不通时看网关日志，比猜快得多：

```bash
kubectl -n himarket logs deploy/higress-gateway --tail=50 | grep -iE "upstream|connect|refused|host|timeout|401"
```

| 日志 | 根因 | 处理 |
|---|---|---|
| `no route` / 404，**耗时只有几毫秒** | 路由**域名没匹配上**，请求在网关匹配阶段就被拒，根本没进上游 | 见下方「毫秒级 404」。核对 console 里路由的真实域名，或临时改成 `*` |
| 404，耗时 > 100ms | 已经打到上游，是上游没这个路径 | 核 `自定义 OpenAI 服务路径`（`/v1` vs `/v1/chat/completions`） |
| `upstream connect error` / `refused` | Pod 到 <MODEL_GW_IP>:32582 不通 | 放通 Pod 网段到 LB VIP:32582（跨集群最常见） |
| `timeout` | 上游慢或超时设太小 | 先调到 300s 再判断 |
| 400 `model not found` | 模型名与上游不一致 | 按第 0 步的 id 逐字对齐 |
| 401（上游返回） | 模型 Key 没填 / 填错 / 少了 `Bearer` | 回 6.3.2 重填 API Key，注意别把 `Bearer ` 字样一起粘进值里 |

**毫秒级 404 的诊断法（本项目实测踩过）**

`code=404` 且 `time_total` 只有 **0.004s 量级**，说明网关在**路由匹配阶段**就返回了，连上游都没碰。判断依据很硬：32B 模型哪怕只回一个 token 也要几百毫秒；连"连不上上游"的 502 都至少几十毫秒。**耗时个位数毫秒的 404 = 域名没命中任何路由。**

此时不要再去改路径、改模型名、改 Key，全都无关。按顺序做三件事：

```bash
# ① 对照组：同入口用已知正常的域名，确认 30080 和域名路由机制本身是好的
curl -sS -o /dev/null -w 'admin  code=%{http_code}\n' -H 'Host: himarket-admin.example.internal' http://<MODEL_GW_IP>:30080/
curl -sS -o /dev/null -w 'portal code=%{http_code}\n' -H 'Host: himarket.example.internal'       http://<MODEL_GW_IP>:30080/

# ② 控制面：看路由的真实 host（这一步直接给出答案）
kubectl get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName,HOST:.spec.rules[*].host'
kubectl get ingress -A -o yaml | grep -E "^\s+- host:|ingressClassName|ai-proxy"

# ③ 候选域名逐个试（把 HOST 列里看到的原值填进去）
for h in model.example.internal himarket.model.example.internal; do
  echo -n "$h -> "
  curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' -m 10 \
    -H "Host: $h" -H 'Content-Type: application/json' \
    -d '{"model":"DeepSeek-R1-Distill-Qwen-32B","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
    http://<MODEL_GW_IP>:30080/v1/chat/completions
done
```

结果判读：

| 现象 | 根因 |
|---|---|
| ① 的 admin/portal 是 200，模型域名 404 | 网关正常，**AI 路由的域名不是这个**，以 ② 的 `HOST` 列为准 |
| ② 里 `CLASS` 为空或不是 `himarket` | 路由没被本网关的 controller 接管（`ingressClass=himarket`），路由不会下发到数据面 |
| ② 的 yaml 里看不到 `ai-proxy` 注解 | AI 路由没真正生成，回 console 重新保存一次 |
| 某个候选域名返回 200 | 用那个域名，并把 console 里路由域名改成它，保持一致 |
| 所有候选都 404 | 路由未生效，把路由域名临时改成 `*` 排除匹配问题，再逐步收紧 |

> **`ai-route-xxx.internal` 这个 `.internal` 后缀是正常的，不要当成故障**：Higress Console 通过「AI 路由管理」创建的路由，落库的 Ingress 名字固定是 `ai-route-<路由名>.internal`（官方示例即 `ai-route-ai-deepseek.internal`），并带 `higress.io/internal: "true"` label。它是控制台托管标记，不代表"只在集群内可用"。

**最硬的一条证据：Envoy access log 里的响应标志（response_flags）**

`kubectl get ingress` 只能证明「配置对象存在」，证明不了「数据面匹配上了」。真正的判定在 access log：

```bash
kubectl -n himarket logs -l app=higress-gateway --tail=300 --prefix --since=10m \
  | grep -i "chat/completions" | tail -10
```

看行尾的 flags 字段：

| flags | 含义 | 对应处理 |
|---|---|---|
| `NR` | **No Route Found**：域名或 path 没匹配到任何路由 | 查 Ingress 的 host/path，或用 `-H 'Host: *'` 排歧义 |
| `UH` | No Healthy Upstream：端点为空 | 查服务来源 / ServiceEntry |
| `UF` | Upstream Connection Failure：连上了但握手/连接失败 | 查安全组、端口 |
| `UT` | Upstream Timeout | 加超时、查模型负载 |
| `-` 或空 | 上游正常响应（404 是上游给的） | 查模型名 / 上游路径 |

`NR` 与「上游返回 404」的区别就在这个字段——两者 HTTP 码都是 404，但根因完全相反。**这也是为什么必须看 logs 而不是只看 curl 返回码。**

**6.3.4 跨集群访问模型：要开什么网络权限**

跨集群接模型时，"要不要找网络组开通"是绕不开的一步。先把链路拆清楚：**发起请求的不是节点、不是 himarket-server，而是 `higress-gateway` 的 Pod（Envoy 数据面）**。

```
higress-gateway Pod (源 IP) ──> LB VIP <MODEL_GW_IP>:30081 ──> 另一集群模型服务
```

源 IP 有两种可能，取决于 CNI：

| CNI 模式 | 出集群时源 IP |
|---|---|
| Calico IPIP / VXLAN、多数 overlay | **SNAT 成节点 IP**（`kubectl get nodes -o wide` 的 INTERNAL-IP） |
| Calico BGP / 直接路由、macvlan、Kube-OVN 子网直通 | **保留 Pod IP**（`kubectl get pods -o wide` 的 IP 列） |

所以申请权限时**两个网段都报上去最稳**，或先实测后只报一个。

**拿网段和端口的命令：**

```bash
# 节点网段
kubectl get nodes -o wide
# Pod 网段
kubectl get pods -n himarket -o wide
# 确认模型端口（不要和 himarket 自己的 30080/30443 混了）
for p in 30081 32582; do echo -n "$p -> "; curl -sS -o /dev/null -w '%{http_code}\n' -m 5 http://<MODEL_GW_IP>:$p/v1/models; done
```

**申请单口径（照抄即可）：**

| 源 | 目的 | 端口/协议 | 用途 |
|---|---|---|---|
| himarket 集群节点网段 `x.x.x.x/24` | `<MODEL_GW_IP>` | `30081/TCP` | AI 网关访问模型服务 |
| himarket 集群 Pod 网段 `<K8S_SERVICE_CIDR>/16` | `<MODEL_GW_IP>` | `30081/TCP` | 同上（CNI 未 SNAT 时需要） |

**先测再申请，别盲目提工单**（在 himarket 集群里起一个临时 Pod 测，它和网关 Pod 走同一套出网路径）：

```bash
kubectl -n himarket run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c 'wget -qO- -T5 http://<MODEL_GW_IP>:30081/v1/models | head -c 200'
```

> `higress-gateway` 容器是 Envoy 镜像，**里面通常没有 curl/wget**，所以必须用临时 Pod 或节点来测，别在那儿反复试 `curl: not found`。

**最准的实测源 IP 方法**（在模型集群侧看，比猜 CNI 模式可靠）：

```bash
# 模型服务所在机器上
ss -tn | grep -E '30081|32582' | head
# 或在模型 Pod 所在节点抓包
tcpdump -ni any tcp port 30081 -c 10
```

看到的 peer 地址就是需要申请放通的源。

**一个容易误判的坑：LB hairpin（发夹弯）**

himarket 集群的节点本身也是这个 LB 的后端（`30080` 就是），所以节点访问 `<MODEL_GW_IP>:30081` 属于"从后端回到自己的 VIP"。部分 LB 不支持 hairpin，表现是**超时而不是拒绝**，很容易被误判成防火墙拦截、白跑一趟工单。判断：办公网能通、集群内不通、且 LB 侧没有拒绝日志 → 优先怀疑 hairpin，改走内网直连（NodePort/ClusterIP/模型侧真实 IP）而不绕 LB。

**6.3.5 两跳架构：himarket-higress → 模型集群-higress → 模型**

目标集群里也有一套 Higress 时，链路变成两跳，**网络和 Host 两个问题要分开解**：

```
himarket 的 higress-gateway Pod
        │  ① 跨集群，走 LB VIP + NodePort
        ▼
LB <MODEL_GW_IP>:30081
        │  ② LB 按端口分流到模型集群节点（网络组配置）
        ▼
模型集群的 higress-gateway
        │  ③ 集群内转发，按 Host/路径匹配那条 AI 路由
        ▼
Kthena / 模型服务
```

**① 端口只需要开一段，别多报**

| 段 | 是否跨防火墙 | 要不要申请 |
|---|---|---|
| himarket Pod/节点网段 → `<MODEL_GW_IP>:30081/TCP` | ✅ 跨集群 | **要，只有这一段** |
| 模型集群 higress → 模型（第三跳） | ❌ 同集群 ClusterIP | 不用，走 Pod 网络 |

常见误报是把"两段"都写进工单，结果网络组问你要模型服务的真实 IP/端口，其实根本不需要。

**② 真正的难点是 Host 头**

中间这层 higress 是按 **域名（Host）** 匹配路由的。而用 IP 访问时，Host 头是 `<MODEL_GW_IP>:30081` → **匹配不上模型集群里的 AI 路由 → 404**。

所以"用 IP 还是域名"这个问题，答案取决于下游那层有没有做 Host 路由：

| 下游（模型集群 higress）的路由 | 上游该怎么填 |
|---|---|
| 域名固定（如 `model.example.internal`），无通配兜底 | **必须让 Host 头等于该域名**，否则 404 |
| 有 `*` 通配路由兜底 | 填 IP 就行 |

让 Host 头等于域名的两种正解：

- **方案 A（推荐，最干净）：给 himarket 集群 CoreDNS 加 hosts**，把服务来源改成 **DNS 类型 + 域名**。这样 Pod 能解析、Host 头天然是域名，两跳都对。

```bash
kubectl -n kube-system edit configmap coredns
# 在 .:53 块内加：
#     hosts {
#       <MODEL_GW_IP>  model-gw.example.internal
#       fallthrough
#     }
kubectl -n kube-system rollout restart deploy/coredns
# 验证
kubectl -n himarket run nettest --rm -it --image=busybox:1.36 --restart=Never -- nslookup model-gw.example.internal
```

- **方案 B（不想动 DNS）：在中间那条 AI 路由上做 host 重写**，把 Host 改成上游认识的值（`higress.io/upstream-host` 一类注解），或干脆给它配一条 `*` 通配路由。

> 注意这一步要修正本手册前半部分的说法：模型前面**没有**第二层 higress 时，"用 IP、不用域名"是对的（HTTP 无 SNI，域名解析不了）；**一旦下游按 Host 路由，Host 头就变成硬要求**，这时必须走方案 A/B，不能再靠纯 IP 蒙混过去。

**③ 排查顺序（两跳必须按跳分离）**

```bash
# 第 1 跳：himarket 侧能不能到 LB 的 30081（临时 Pod，与网关同出网路径）
kubectl -n himarket run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c 'wget -qO- -T5 http://<MODEL_GW_IP>:30081/v1/models | head -c 200'

# 第 2 跳：模型集群那侧 30081 是谁在监听
kubectl get svc -A | grep 30081        # 在模型集群执行，确认是 higress-gateway 的 NodePort
kubectl get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName,HOST:.spec.rules[*].host'
```

第 2 跳的命令要在**模型集群**执行，拿到的 `HOST` 就是第 1 跳必须发送的 Host 值。

**实测案例（本项目）：两跳的 Host 对不上，就是那个毫秒级 404**

模型集群（生产侧）的路由表：

```
higress-system  ai-route-ds.internal      higress  model-gw.example.internal
higress-system  ai-route-ds32b.internal   higress  model-gw.example.internal
```

himarket 侧的路由域名却是 `himarket.model.example.internal`。两跳的 Host 完全不同：

| 跳 | 发送的 Host | 期望匹配 |
|---|---|---|
| himarket higress → LB:30081 | `himarket.model.example.internal`（透传）或 `<MODEL_GW_IP>:30081`（用 IP 时） | ❌ 都不是 `model-gw.example.internal` |
| 模型集群 higress 内部 | 必须是 `model-gw.example.internal` | ✅ |

结论：**himarket 侧的「AI 服务提供者」必须把上游的 Host 变成 `model-gw.example.internal`**，否则永远 404。做法是把服务来源从「固定地址」改成「**DNS 域名**」，填 `model-gw.example.internal:30081`。

**实测验证（先做这条，能直接判定要不要报端口）**

```bash
# 在 himarket 集群节点执行
curl -sS -o /tmp/m.json -w 'code=%{http_code} time=%{time_total}s\n' -m 30 \
  -H 'Host: model-gw.example.internal' http://<MODEL_GW_IP>:30081/v1/models
cat /tmp/m.json
```

本项目实测结果：

```
code=200 time=0.005957s
{"object":"list","data":[
  {"id":"DeepSeek-R1-Distill-Llama-70B","owned_by":"kthena"},
  {"id":"DeepSeek-R1-Distill-Qwen-1.5B","owned_by":"kthena"},
  {"id":"DeepSeek-R1-Distill-Qwen-32B","owned_by":"kthena"},
  {"id":"qwen-storm","owned_by":"kthena"}]}
```

**这一条 200 同时证明了四件事，直接省掉一轮工单**：

1. himarket 节点 → LB:30081 → 模型集群 higress → Kthena **全网可达，防火墙无需开通**
2. 30081 就是模型集群 higress 的入口端口
3. 正确的 Host 是 `model-gw.example.internal`（不带端口也行）
4. 模型真实 id 有四个，32B 那个是 `DeepSeek-R1-Distill-Qwen-32B`

对比同一路径**不带 Host** 时的 `code=404 time=0.0047s`——两次耗时都在毫秒级，说明差异**只在 Host 匹配**，与网络、端口、模型全部无关。

> 补充：节点通只证明「节点 → LB」这一段。真实调用来自 `higress-gateway` 的 Pod，还要用临时 Pod 复核一次（它走同一套出网路径，CNI 会 SNAT 成节点 IP，通常与节点结果一致）：
>
> ```bash
> kubectl -n himarket run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
>   sh -c 'nslookup model-gw.example.internal; wget -qO- -T10 http://model-gw.example.internal:30081/v1/models | head -c 200'
> ```
>
> 这条同时验证 CoreDNS 的 hosts 是否已生效——能解析出 `<MODEL_GW_IP>` 且能取到模型列表，两跳就都通了。

> **⚠️ 关键坑：给 Pod 加 `hostAliases` 对 Envoy 无效**
>
> Envoy 用自己的 DNS 解析器（c-ares）直接向 DNS server 发查询，**不读容器的 `/etc/hosts`**。所以 `hostAliases` 只对普通应用有效，对 higress-gateway 的 DNS 解析无效。想让 `model-gw.example.internal` 在 Pod 里可解析，**只能改 CoreDNS**：
>
> ```bash
> kubectl -n kube-system edit configmap coredns
> # .:53 块内加：
> #     hosts {
> #       <MODEL_GW_IP>  model-gw.example.internal
> #       fallthrough
> #     }
> kubectl -n kube-system rollout restart deploy/coredns
> # 验证（用临时 Pod，因为网关镜像没有 nslookup）
> kubectl -n himarket run nettest --rm -it --image=busybox:1.36 --restart=Never -- nslookup model-gw.example.internal
> ```
>
> 注意 `hosts` 插件块要放在 `kubernetes` 插件**之前**，否则会被集群内域名优先匹配；加 `fallthrough` 让未命中的继续走后续插件。

**6.3.6 不改 DNS 的替代方案：用 `upstream-vhost` 改写 Host（推荐先试这个）**

改 CoreDNS 是全集群级操作，有些环境不方便动。Higress 原生支持在 Ingress 上直接改写转发时的 Host 头：

| 注解 | 作用域 | 说明 |
|---|---|---|
| `higress.io/upstream-vhost` | Ingress | 匹配该路由的请求转发给后端时，**把 Host 头改成指定值** |
| `nginx.ingress.kubernetes.io/upstream-vhost` | Ingress | 同上，nginx 前缀与 higress 前缀等价 |

也就是说：**上游继续用固定 IP（不需要任何 DNS 解析），只在路由上把 Host 改写成 `model-gw.example.internal`**。

```bash
# himarket 集群，给那条 AI 路由加注解
kubectl -n himarket annotate ingress ai-route-deepseek32b.internal \
  higress.io/upstream-vhost="model-gw.example.internal" --overwrite

# 确认生效
kubectl -n himarket get ingress ai-route-deepseek32b.internal \
  -o jsonpath='{.metadata.annotations.higress\.io/upstream-vhost}{"\n"}'
```

服务来源保持「固定地址 `<MODEL_GW_IP>:30081`」不变，不用建 DNS 类型来源，不用碰 CoreDNS。

**AI 路由在 K8s 里到底是什么（三层，别混淆）**

控制台里的「AI 路由」没有独立的 CRD，它由三个标准对象拼起来：

| 层 | 资源 | 管什么 | 对应控制台页面 |
|---|---|---|---|
| 路由 | **Ingress**（`networking.k8s.io/v1`，名字 `ai-route-<名>.internal`） | 域名、路径匹配、**Host 改写** | AI 路由管理 |
| 上游 | **McpBridge**（`networking.higress.io/v1`，固定名 `default`） | 后端地址（static IP / dns 域名）、协议、端口 | 服务来源 |
| 插件 | **WasmPlugin**（`extensions.higress.io/v1alpha1`，`ai-proxy`） | provider 类型、模型映射、上游密钥 | AI 服务提供者管理 |

所以我们加的 `higress.io/upstream-vhost` 是**第一条（标准 Ingress）的注解**，与「普通 Ingress 配置」完全同源，不是什么 AI 专有配置。这也是它为什么对任何 Ingress 都生效。

**为什么改了 Host 却不需要 DNS 解析**——因为这是两个不同层面的东西：

```
连接目标（网络层）  ← 由 McpBridge 的 cluster 决定，是 IP <MODEL_GW_IP>:30081，不做 DNS
Host 头（HTTP 层）  ← 由 upstream-vhost 改成 model-gw.example.internal，只是一个请求头字符串
```

Envoy 先按 cluster 里的 IP 建连，再在 router 阶段把 `:authority` 改写成 `model-gw.example.internal` 发过去。下游 Higress 只读这个头来匹配路由，不会去解析它。**所以改 Host 和解析域名是两件互不相关的事**，这也是方案 A 能绕开 CoreDNS 的根本原因。

**取完整 yaml（照着看，别整体 apply）**

```bash
kubectl -n himarket get ingress ai-route-deepseek32b.internal -o yaml
```

典型形态（字段值以实际 dump 为准，尤其是 `destination` 和 `path`）：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ai-route-deepseek32b.internal
  namespace: himarket
  annotations:
    higress.io/comment: PLEASE DO NOT EDIT DIRECTLY. This resource is managed by Higress.
    higress.io/destination: DeepSeek-R1-Distill-Qwen-32B.static:80   # 上游，指向 McpBridge 里的 static 条目
    higress.io/internal: "true"
    higress.io/resource-definer: higress
    higress.io/upstream-vhost: model-gw.example.internal        # ← 本次新增的 Host 改写
  labels:
    higress.io/internal: "true"
    higress.io/resource-definer: higress
spec:
  ingressClassName: himarket
  rules:
  - host: himarket.model.example.internal                   # himarket 侧对外域名
    http:
      paths:
      - path: /v1
        pathType: Prefix
        backend:
          resource:                                # 注意：不是 service，是 McpBridge 引用
            apiGroup: networking.higress.io
            kind: McpBridge
            name: default
```

> **千万不要用 `kubectl apply -f` 整体覆盖这个文件**。它是控制台托管对象，手写 yaml 一旦漏了 `higress.io/destination`、`backend.resource` 这些字段，路由立刻报废，而且控制台可能显示正常但数据面是错的。要改就用 `kubectl annotate`（只碰 annotations）或 `kubectl edit`（原位修改）。

**两个方案怎么选：**

| | 方案 A：`upstream-vhost` 注解 | 方案 B：CoreDNS + DNS 类型来源 |
|---|---|---|
| 改动范围 | 一条 Ingress 注解 | 集群 DNS + 服务来源 |
| 需要改生产集群 | 否 | 否 |
| 需要域名可解析 | **不需要** | 需要 |
| 影响面 | 仅这条路由 | 全集群 DNS（虽只加一条记录） |
| 被 console 覆盖风险 | **有**，见下 | 无 |
| 回滚 | 删注解即可 | 删 hosts 记录 + 重启 CoreDNS |

> **方案 A 的唯一风险**：AI 路由的 Ingress 由控制台托管（带 `higress.io/comment: PLEASE DO NOT EDIT DIRECTLY`）。**在控制台里重新保存该路由时，注解可能被重写掉**。表现是"昨天好好的，今天又 404"。所以用它必须做两件事：① 在运维记录里写明这条注解；② 每次在控制台改过路由后，复核注解是否还在。
>
> 另外 ai-proxy 插件与 host_rewrite 谁后生效，取决于版本实现顺序。加完注解务必实际打一次网关确认（看 `time` 是否从毫秒级变成百毫秒级），不要只看注解是否存在。

**如果加注解后仍是毫秒级 404**：说明 ai-proxy 覆盖了 Host，此时回退到方案 B（CoreDNS + DNS 类型来源），那条路径是确定生效的。

**✅ 本项目最终验证结果（方案 A 生效）**

```bash
kubectl -n himarket annotate ingress ai-route-deepseek32b.internal \
  higress.io/upstream-vhost="model-gw.example.internal" --overwrite
```

一条注解即通，服务来源保持固定地址 `<MODEL_GW_IP>:30081` 未改，CoreDNS 未动：

```
code=200  time=3.295932s
{"id":"chatcmpl-478afb73-...","object":"chat.completion",
 "model":"DeepSeek-R1-Distill-Qwen-32B",
 "choices":[{"message":{"role":"assistant","content":"你好！很高兴为您提供服务..."},
 "finish_reason":"length"}],
 "usage":{"prompt_tokens":6,"total_tokens":26,"completion_tokens":20},
 "system_fingerprint":"vllm-0.22.1-tp4-6c8c5172"}
```

**判断通的依据不是 200，而是 `time`**：`0.0047s → 3.2959s`，耗时放大约 700 倍，说明请求真的进了 vLLM 推理，而不是在网关本地被拒。以后遇到 200 但耗时仍是毫秒级的，要怀疑命中了缓存或兜底路由。

两个来自响应的信息：

- 后端是 **vLLM 0.22.1（TP=4）**，OpenAI 兼容层完整，`usage` 字段可直接用于计量
- `finish_reason: "length"` 且 content 里有 `</think>`：这是 R1 系列先输出思考过程的正常表现，**`max_tokens` 给小了会全被思考吃光**，产品里别设太小

**注解巡检与自愈（建议做成定时任务）**

这条注解是整条链路最脆弱的一环：控制台保存路由、Helm 升级、路由重建都可能让它消失，而症状是「毫秒级 404」，很容易被误判成模型或网络问题。

```bash
#!/bin/bash
# himarket-ai-route-check.sh —— 检查并自动补回 upstream-vhost 注解
NS=himarket
ING=ai-route-deepseek32b.internal
WANT=model-gw.example.internal

cur=$(kubectl -n $NS get ingress $ING -o jsonpath='{.metadata.annotations.higress\.io/upstream-vhost}' 2>/dev/null)

if [ "$cur" = "$WANT" ]; then
  echo "OK: upstream-vhost = $cur"
  exit 0
fi

echo "MISSING: upstream-vhost = '${cur}' ，正在补回 ${WANT}"
kubectl -n $NS annotate ingress $ING higress.io/upstream-vhost="$WANT" --overwrite
echo "已补回，请验证："
echo "curl -sS -o /dev/null -w 'code=%{http_code} time=%{time_total}s\n' -m 60 \\"
echo "  http://<MODEL_GW_IP>:30080/v1/chat/completions -H 'Host: himarket.model.example.internal' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"model\":\"DeepSeek-R1-Distill-Qwen-32B\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":20}'"
```

判定标准始终是 **`time` 的量级**：3 秒级＝通，毫秒级＝注解丢了或路由没匹配。

### 6.3.7 桌面客户端（Chatbox / Cherry Studio / OpenWebUI）接入

节点 curl 通了，不代表办公电脑能通。这一节是「我的电脑上连不上」的专用排查。

**填法（以 Chatbox 为例）**

| 字段 | 填什么 | 说明 |
|---|---|---|
| API 模式 | OpenAI API 兼容 | |
| API 主机 | `http://himarket.model.example.internal:30080` | 只到端口，**不要**带 `/v1` |
| API 路径 | `/chat/completions` | 客户端会自动补 `/v1` |
| API 密钥 | HiMarket 门户的 **Consumer Key** | 不是模型 Key，也不是随便一个占位串（路由挂了 key-auth 时会是 401） |
| 模型 | `DeepSeek-R1-Distill-Qwen-32B` | 逐字一致 |

**唯一验收标准：客户端下方那行「预览」必须拼成**

```
http://himarket.model.example.internal:30080/v1/chat/completions
```

预览里出现 `/v1/v1/`、或缺少 `/v1`，都是填错，必 404。

**外部访问 404 的三条根因（按概率）**

| 根因 | 判据 | 处理 |
|---|---|---|
| Windows hosts 未生效 / 解析到别处 | `curl -v` 里 `Trying x.x.x.x` 不是 <MODEL_GW_IP> | 修 hosts（管理员权限，UTF-8 无 BOM），或改用 IP+`-H Host:` |
| `upstream-vhost` 注解被覆盖 | 从节点 curl 也是毫秒级 404 | 重新 annotate，见 6.3.6 |
| 主机名拼写/端口不符 | `curl -v` 里 `Host:` 与路由域名不一致 | 逐字核对 `kubectl get ingress -A` 的 HOST 列 |

**一刀切开的命令**：在 Windows 上绕过 DNS，直接用 IP + Host 头打同一个网关。

```powershell
curl.exe -sS -o NUL -w "code=%{http_code} time=%{time_total}\n" -m 60 ^
  http://<MODEL_GW_IP>:30080/v1/chat/completions ^
  -H "Host: himarket.model.example.internal" -H "Content-Type: application/json" ^
  -d "{\"model\":\"DeepSeek-R1-Distill-Qwen-32B\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":20}"
```

| 结果 | 结论 |
|---|---|
| `code=200 time=3.x s` | 服务端完全正常，**问题在 Windows 的 DNS/hosts**，用 `curl -v` 看解析出的 IP |
| `code=404 time=0.00x s` | 服务端路由没匹配，回查注解与 HOST 列（与客户端无关） |
| `code=401` | 路由正常，只是 API 密钥不是有效 Consumer Key |
| `code=000` | 客户端到 LB 网络不通 |

> **不要用浏览器验证**：浏览器只能发 GET，而对话接口是 POST，`/v1/models` 又不保证被转发，看到的 404 会被误判。

**`curl -v` 响应头三步判读（比看状态码精确）**

| 响应头 | 结论 |
|---|---|
| 有 `server: istio-envoy` | 请求确实到了 Higress，不是 DNS 走偏 |
| **有 `x-envoy-upstream-service-time`** | **已转发到上游并拿到响应**，404 是上游给的 → 查 Host 改写、上游路径，而不是查路由 |
| 无 `x-envoy-upstream-service-time` 且 404 | Envoy 本地 `NR`，路由根本没匹配 → 查 HOST 列与 ingressClass |
| `x-envoy-upstream-service-time: 2` 这种个位数毫秒 + 404 | 上游极快拒绝：Host 头不对或路径不存在，模型没参与 |

对照 `req-cost-time`（网关总耗时）与 `x-envoy-upstream-service-time`（上游耗时）：两者都只有个位数毫秒时，**对话请求绝无可能真的跑到 vLLM**（真实推理 ≥ 数百毫秒），可据此直接排除「模型慢/超时」方向。

**同一入口、两种客户端结果不一致时的第一条检查**

节点 curl 通（3s）而办公电脑 404（2ms），说明两者之间**只有配置变化或源 IP 差异**。先做两件事，不要先怀疑网络：

```bash
# 1. 注解还在不在（控制台保存过就会丢）
kubectl -n himarket get ingress ai-route-deepseek32b.internal \
  -o jsonpath='{.metadata.annotations.higress\.io/upstream-vhost}{"\n"}'

# 2. 在节点上重跑同一条 curl，与电脑结果对照
curl -sS -o /dev/null -w 'node code=%{http_code} time=%{time_total}s\n' -m 300 \
  http://<MODEL_GW_IP>:30080/v1/chat/completions \
  -H 'Host: himarket.model.example.internal' -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-R1-Distill-Qwen-32B","messages":[{"role":"user","content":"hi"}],"max_tokens":20}'
```

节点也 404 → 配置被改（注解丢失最常见）；节点 200 而电脑 404 → 才轮到源 IP / 客户端问题。

**注解在、Host 对、节点也 404 时：问题在 provider 层**

这种情况说明路由和注解都没问题，是 ai-proxy 的转发目标变了。实测案例：节点与电脑都返回 `404 / 4.6ms`，`x-envoy-upstream-service-time: 2`，而注解查询返回正确的 `model-gw.example.internal`。根因是控制台里把「自定义 OpenAI 服务」从**选择服务**改成了**输入 URL** —— 此后 Host 由 URL 里的主机决定，`upstream-vhost` 注解被绕过，下游 higress 又匹配不上。

判据链：`x-envoy-upstream-service-time` 存在（到了上游）＋ 注解正确 ＋ 时间个位数毫秒 = **上游凭 Host/路径拒绝**，与网络、注解、模型均无关。

三条命令取证：

```bash
# 1. 上游直连（绕开 himarket 网关，验证模型侧本身）
curl -sS -o /dev/null -w 'upstream code=%{http_code} time=%{time_total}s\n' -m 60 \
  -H 'Host: model-gw.example.internal' -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-R1-Distill-Qwen-32B","messages":[{"role":"user","content":"hi"}],"max_tokens":20}' \
  http://<MODEL_GW_IP>:30081/v1/chat/completions

# 2. 路由的转发目标有没有变
kubectl -n himarket get ingress ai-route-deepseek32b.internal -o yaml \
  | grep -E "destination|path:|host:|upstream-vhost"

# 3. provider 配置（ai-proxy 的 WasmPlugin）
kubectl get wasmplugin -A | grep -i ai-proxy
```

修法：回到 Higress 控制台【AI 网关】→【AI 服务提供者管理】→ 编辑该 provider，把「配置方式」改回**选择服务**并选中 `<服务名>.static:80`，路径保持 `/v1`，保存后**再次**检查注解是否还在。

**三路径定位法：区分「路径拼错」与「上游不可用」**

怀疑路径被多拼或漏拼时，直接在模型侧打三个候选路径，比看任何界面都快：

```bash
for p in /v1/chat/completions /v1/v1/chat/completions /chat/completions; do
  echo -n "$p  ->  "
  curl -sS -o /dev/null -w '%{http_code}  %{time_total}s\n' -m 60 \
    -H 'Host: <上游路由域名>' -H 'Content-Type: application/json' \
    -d '{"model":"<模型id>","messages":[{"role":"user","content":"hi"}],"max_tokens":20}' \
    http://<上游IP:端口>$p
done
```

实测参考结果（vLLM + 模型侧 higress）：

| 路径 | 返回 | 说明 |
|---|---|---|
| `/v1/chat/completions` | `200 / 3.1s` | 上游正常，模型侧无问题 |
| `/v1/v1/chat/completions` | `500 / 0.12s` | 前缀重复 |
| `/chat/completions` | `404 / 0.003s` | 缺 `/v1`，**与网关返回的 404 对得上就说明是这种** |

**关键用法**：把网关那条 404 的耗时与表中第三行对照。若几乎一致（都是个位数毫秒），说明 ai-proxy 发出去的就是 `/chat/completions`——即 provider 的「自定义 OpenAI 服务路径」不是 `/v1`（被改成 `/` 或清空），而不是模型或网络问题。

修法二选一：控制台把该字段填成 `/v1`；或把上游地址直接写成 `http://IP:PORT/v1`（在「输入 URL」模式下）。改完保存，**复查 `upstream-vhost` 注解是否还在**，再打一次网关。

**比注解更优先的一处：「自定义 OpenAI 服务主机域」**

AI 服务提供者编辑页里还有一个字段容易被忽略——**「自定义 OpenAI 服务主机域」**。它由 ai-proxy 插件直接设置发给上游的 `Host` 头，**执行时机在路由之后，会盖掉 `higress.io/upstream-vhost` 注解**。

若这里填的是服务名（如 `deepseek-r1-distill-qwen-32b.static`），上游收到的 Host 就是这串服务名，下游 higress 匹配不上，返回个位数毫秒的 404——症状与本节的「注解丢失」「路径缺前缀」几乎一样，极易误判。

| 字段 | 应填 | 说明 |
|---|---|---|
| 自定义 OpenAI 服务路径 | `/v1` | 路径前缀，不能是 `/` 或空 |
| **自定义 OpenAI 服务主机域** | **上游路由域名**（如 `model-gw.example.internal`） | 决定 Host 头；留空则沿用服务名 |

> **控制台会自动填这个字段**：选中服务后，主机域默认被推导成服务名（如 `deepseek-r1-distill-qwen-32b.static`），**不是用户手写的**。这个默认值只在「上游路由不校验 Host」时可用；一旦下游是按域名匹配的 higress，就必须手动改成真实域名。改动后保存，若发现它又被改回服务名，说明该版本强制推导——此时改走「服务来源=DNS 域名」的方式，让推导结果天然等于目标域名（见 6.3.6 方案 B）。

填对这个字段后，`upstream-vhost` 注解可以删掉（两处都设时以前者为准，留着容易让人误判到底是哪一层在起作用）。删注解的命令：

```bash
kubectl -n himarket annotate ingress ai-route-deepseek32b.internal higress.io/upstream-vhost-
```

**排查优先级（同样是「毫秒级 404」，从高到低）**：① 主机域字段填错 → ② provider 路径不是 `/v1` → ③ `upstream-vhost` 注解丢失 → ④ 路由 HOST 列不符。

### 6.3.8 决定性证据：`openaiCustomUrl` 必须是**完整端点**（本次真实根因）

前面 6.3.6、6.3.7 的所有症状（毫秒级 404、`/v1/models` 能通、对话接口不通），都可以用一条命令一次性定死——直接看 ai-proxy 插件里的 provider 配置。

**先纠正命名**：WasmPlugin 名字带后缀，不叫 `ai-proxy`。

```bash
kubectl -n himarket get wasmplugin
# ai-proxy.internal      → 要查的是这个
# ai-statistics-2.0.3
# key-auth.internal

kubectl -n himarket get wasmplugin ai-proxy.internal -o yaml | grep -iE "url|host|path|model"
```

本次实测输出（关键两行）：

```yaml
id: model.example.internal
openaiCustomUrl: http://model-gw.example.internal/v1                              # ← 问题所在：只有前缀
openaiCustomUrl: http://<CODING_PLAN_IP>:8082/glm5/v1/chat/completions   # ← 对照物：完整端点
activeProviderId: model.example.internal
```

**判读**：`openaiCustomUrl` 不是「前缀」，而是**最终要请求的那个完整 URL**。它是 HiMarket 用「自定义主机域 + 自定义服务路径」拼出来的。这两行并排放着就是结论——另一个 provider 写的是 `.../glm5/v1/chat/completions`（完整端点），而 `model.example.internal` 写的是 `http://model-gw.example.internal/v1`（只有前缀），于是 ai-proxy 把对话请求改写成 `/v1` 发出去，下游 higress 匹配到路由、转发给 vLLM，vLLM 对 `/v1` 返回 404——个位数毫秒，模型根本没参与推理。

**为什么 `/v1/models` 却是 200**：ai-proxy 只对 `/chat/completions`、`/embeddings` 这类它会解析的端点做 URL 改写，`/v1/models` 不在其列，**原样透传**。所以：

| 请求 | 结果 | 含义 |
|---|---|---|
| `/v1/models` | `200 / 8ms` | 网络、McpBridge、`upstream-vhost`、路由 Host **全部正确**（这条 200 已经把 6.3.6/6.3.7 的怀疑全部排除） |
| `/v1/chat/completions` | `404 / 3.8ms` | 不是路由问题，是**改写后的路径**被上游拒绝 |

两条同时成立时，唯一可能的层就是 provider 的 `openaiCustomUrl`。

**修法（推荐走控制台，可持久化）**

【AI 网关】→【AI 服务提供者管理】→ 编辑 `model.example.internal` → 把「自定义 OpenAI 服务路径」由 `/v1` 改成 **`/v1/chat/completions`** → 保存。

保存后复查一行，确认拼出来的就是完整端点：

```bash
kubectl -n himarket get wasmplugin ai-proxy.internal -o yaml \
  | grep -n "openaiCustomUrl" -A0
# 期望：openaiCustomUrl: http://model-gw.example.internal/v1/chat/completions
```

**先临时验证也可以**（不改控制台，10 秒见效，但控制台一保存就被覆盖）：

```bash
kubectl -n himarket get wasmplugin ai-proxy.internal -o yaml > /tmp/ai-proxy.bak.yaml
kubectl -n himarket edit wasmplugin ai-proxy.internal
# 把 openaiCustomUrl: http://model-gw.example.internal/v1  改成  .../v1/chat/completions
```

改完等 5~10 秒（插件配置异步下发到网关 Pod），再打网关：

```bash
curl -sS -o /tmp/r.json -w 'code=%{http_code} time=%{time_total}s\n' -m 300 \
  http://<MODEL_GW_IP>:30080/v1/chat/completions \
  -H 'Host: himarket.model.example.internal' -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-R1-Distill-Qwen-32B","messages":[{"role":"user","content":"hi"}],"max_tokens":20}'
```

`code=200` + `time=3s` 量级 = 定案。若仍是毫秒级 404，再 `grep` 一次确认改动没被控制台/Operator 回滚。

**端口为什么可以不写**：`openaiCustomUrl` 里的主机只用于拼路径与（可能被覆盖的）Host，真正的 TCP 目标是 McpBridge 的 `destination`（`<MODEL_GW_IP>:30081`），Host 由 `higress.io/upstream-vhost=model-gw.example.internal` 决定。所以 `http://model-gw.example.internal/v1/chat/completions` **不带端口是对的**，别为了「看着完整」去补 `:30081`。

**一句话记住**：`openaiCustomUrl` = 完整端点（含 `/chat/completions`）；Higress AI 路由里的「路径」= 前缀（`/` 或 `/v1`）。两个地方的字段语义不同，填混了就是「路由 200 模型 404」。

**源码语义（ai-proxy `provider/openai.go`，可据此反推，不必猜）**

```go
// CreateProvider：把 openaiCustomUrl 拆成 domain + path
customUrl := strings.TrimPrefix(strings.TrimPrefix(config.openaiCustomUrl, "http://"), "https://")
pairs := strings.SplitN(customUrl, "/", 2)   // ["model-gw.example.internal", "v1/chat/completions"]
customPath := "/" + pairs[1]                  // "/v1/chat/completions"
isDirectCustomPath := isDirectPath(customPath) // 以 /completions、/models、/embeddings… 结尾 → true

// TransformRequestHeaders
if m.isDirectCustomPath {
    util.OverwriteRequestPathHeader(headers, m.customPath)   // 整体替换，不看入站路径
} else if apiName != "" {
    util.OverwriteRequestPathHeaderByCapability(headers, string(apiName), m.config.capabilities)
}
util.OverwriteRequestHostHeader(headers, m.customDomain)     // Host ← URL 里的域名
```

两个可直接用于判据的推论：

1. `openaiCustomUrl` 以 `/completions`、`/models` 等结尾（`isDirectCustomPath=true`）时，**所有**请求的 path 都会被替换成它——连 `/v1/models` 也会变成 `/v1/chat/completions`。所以「`/v1/models` 返回 404」这件事本身就说明**插件没有生效**（或这条请求没走到挂了插件的路由），而不是路径配错。
2. 插件会自己把 `:authority` 设成 URL 里的域名，因此 provider 生效时 Host 不依赖 `upstream-vhost` 注解；注解只在插件未生效（透传）时才是唯一 Host 来源。

### 6.3.9 最后一跳：Host，以及「注解为什么老是被冲掉」

6.3.8 改完 `openaiCustomUrl` 后如果还是 404，且满足下面三条，结论就只有一个——**Host**：

| 事实 | 实测 | 含义 |
|---|---|---|
| `/v1/models` 与 `/v1/chat/completions` **同时** 404 | 都是个位数毫秒 | 不再是路径问题（路径错只会影响对话端点） |
| 响应头**有** `x-envoy-upstream-service-time: 2` | 已转发到上游 | 路由匹配成功、网络通，是**上游按 Host/路径拒绝** |
| `upstream-vhost` 注解查询**返回空** | 注解不在了 | Host 回退成 `himarket.model.example.internal`，模型侧 higress 没有这个域名 → 2ms 404 |
| 模型侧直连 `:30081/v1/chat/completions`（Host=`model-gw.example.internal`） | `200 / 3.0s` | 上游本身完全健康 |

两条命令闭环：

```bash
kubectl -n himarket annotate ingress ai-route-deepseek32b.internal \
  higress.io/upstream-vhost="model-gw.example.internal" --overwrite

curl -sS -o /dev/null -w 'chat code=%{http_code} t=%{time_total}s\n' -m 300 \
  http://<MODEL_GW_IP>:30080/v1/chat/completions \
  -H 'Host: himarket.model.example.internal' -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-R1-Distill-Qwen-32B","messages":[{"role":"user","content":"hi"}],"max_tokens":20}'
```

> **改完立刻测会误判**：`kubectl annotate` 之后 Envoy 需要 3~10 秒把配置下发给 Pod（网关有多个副本，要全部刷新）。实测：加注解后立刻打是 `404 / 4.5ms`，20 秒后再打是 `200 / 3.077s`。所以别用第一次的结果做判断，等 10 秒、或者连打两次取第二次。

**注解为什么反复消失**：HiMarket 在控制台保存「AI 服务提供者 / AI 路由」时，会**重写整条 ingress 的 `metadata.annotations`**，只保留它自己认识的几个键（`higress.io/destination`、`enable-proxy-next-upstream`、`ignore-path-case` 等），手加的 `upstream-vhost` 一律丢弃。所以「保存一次 → 404 一次」是必然，不是巧合。

**持久方案：把 Host 认到模型侧，从此不依赖注解**

在**模型集群**那条路由上加一个域名 `himarket.model.example.internal`（与原有 `model-gw.example.internal` 并存），请求带着原样 Host 过去就能命中，himarket 侧不需要任何 Host 改写：

- 首选：模型集群 Higress 控制台 →【AI 路由】→ 编辑 `ds32b` → 域名加一行 `himarket.model.example.internal` → 保存
- 手工：`kubectl -n <模型命名空间> edit ingress ai-route-ds32b.internal`，在 `spec.rules` 里复制一份规则、只改 `host`（**前提是这条 ingress 不由 Operator 重建**；若是 Kthena 自动生成的，改完会被覆盖 → 改走下面一条）
- 保底：在模型集群新建一条独立 ingress，`host: himarket.model.example.internal`、路径 `/v1` Prefix、后端指向与原路由相同的 Service，不受 Operator 影响

代价是模型集群多认一个域名；收益是 himarket 侧任何保存都不再影响链路。

> **实测结论（推荐就按这个做）**：在模型集群的 AI 路由里加一个新域名 `ds32b-local.model.example.internal`（与 `model-gw.example.internal` 并存），然后**删掉** himarket 侧的 `upstream-vhost` 注解，链路仍然 `200 / 3.08s`。注解彻底不需要了，门户保存也不会再断。这就是终态：**两边各自认域名，中间不做任何 Host 改写**。

**过渡期兜底**：留一个 3 行脚本，发现毫秒级 404 就跑一次。

```bash
cat > /usr/local/bin/fix-vhost.sh <<'EOF'
#!/bin/bash
kubectl -n himarket annotate ingress ai-route-deepseek32b.internal \
  higress.io/upstream-vhost="model-gw.example.internal" --overwrite
echo "vhost restored"
EOF
chmod +x /usr/local/bin/fix-vhost.sh
```

### 6.3.10 用网关访问日志的 `route_name` 定位「被别的路由抢走」

改什么都是 404、注解也在、路径也对时，别看配置了，直接看网关访问日志——它一行就说清请求落到了哪条路由、发给了谁：

```bash
kubectl -n himarket logs deploy/higress-gateway --tail=100 | grep -i "chat/completions" | tail -3
```

关注四个字段：

| 字段 | 含义 | 判读 |
|---|---|---|
| `route_name` | **实际命中的 ingress/路由名** | 与你改注解的那条不一致 → 请求根本没走这条，改它当然没用 |
| `upstream_cluster` / `upstream_host` | 发给了谁 | `DeepSeek-...-32B.static` + `<MODEL_GW_IP>:30081` 才对；出现别的 `.static` + 别的 IP 就是被抢 |
| `upstream_service_time` | 上游耗时（ms） | 个位数 = 上游秒拒（Host/路径不对）；几百 = 真的推理了 |
| `response_code` + `duration` | 结果与总耗时 | `200` + `duration` 上万毫秒 = 流式对话成功 |

实测案例（同一域名 `himarket.model.example.internal` 下两条路由并存）：

```
route_name=ai-route-coding.internal  upstream_host=<CODING_PLAN_IP>:8082   404  ← 被 coding 路由抢走
route_name=ai-route-deepseek32b.internal    upstream_host=<MODEL_GW_IP>:30081    200  ← 正确路由，Chatbox 流式 174s
```

同一个 Host + `/v1/chat/completions` 的请求，前后落在不同路由上，说明**两条路由在争同一个域名**。这时的唯一稳定解不是反复补注解，而是**给目标路由一个独占域名**（HiMarket 里改 AI 路由域名，或另建一条），让竞争消失。

判据补充：`authority` 里带不带端口（`himarket.model.example.internal:30080`）不影响匹配，Envoy 匹配时会去掉端口，不用管。

### 6.4 第 2 步：在 HiMarket 建 Model API 产品

后台 `http://himarket-admin.example.internal:30080` →【API Products】→【创建】→ 类型 **Model API**。

| 字段 | 建议值 |
|---|---|
| 产品名称 | `DeepSeek-32B`（开发者看到的名字） |
| 产品类型 | `Model API` |
| 描述 | 内网自建 DeepSeek-32B，OpenAI 兼容 |
| 类别 | `大语言模型` |
| 图标 | URL 或上传 |

创建后详情页里 Model 类型会多一组参数（【模型配置】或创建表单展开项），**不能留空**：

| 参数 | 填什么 | 为什么 |
|---|---|---|
| Model | `DeepSeek-R1-Distill-Qwen-32B` | **实测的真实 id**，必须逐字一致。Kthena 按名称精确匹配，写错会报 `can't find model server` |
| Max Tokens | `4096`（≤ 模型上限） | 太大易超时，太小回答被截断 |
| Temperature | `0.7` | 通用对话 |
| 联网搜索 | 关 | 内网没有搜索服务，开了会报错 |

### 6.5 第 3 步：Link API 关联

详情页 →【Link API】/【关联 API】：

1. 资源类型：`Model API`（部分版本显示 `AI 路由`）
2. 来源：`Higress`
3. 列表里选中 `deepseek-32b`
4. 点【关联】

状态：**待配置** → **待发布**。

列表为空只有一个原因：Higress 里那条路由没建成功，或建在别的域名/别的实例下。回 6.3 核字段，别在这儿反复刷新。

### 6.6 第 4 步：写 Usage Guide

详情页 →【Usage Guide】，抄这段，把模型名换成你的：

```markdown
## 调用方式
- Base URL: http://<MODEL_GW_IP>:30080
- Host: model.example.internal
- 认证: Authorization: Bearer <你的 Consumer API Key>
- 模型名: deepseek-32b

## 示例
curl http://<MODEL_GW_IP>:30080/v1/chat/completions \
  -H "Host: model.example.internal" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-32b","messages":[{"role":"user","content":"你好"}]}'

## 限制
- 上下文 32K，Max Tokens 4096
- 超时 300s，长文本请用流式
```

保存。

> Usage Guide 里只能出现 **Consumer Key 的获取方式**，绝对不能写模型 Key，也不要贴任何 `sk-` 开头的真实值——这一页是给所有开发者看的。

### 6.7 第 5 步：发布到门户

详情页 →【发布到门户】→ 勾 `demo` →【发布】。门户左侧【模型】里就能看到这张卡片。

### 6.8 第 6 步：开发者侧订阅 + 验收

1. 门户注册（Security 已设自动审批则直接可登录）
2. 头像 →【消费者管理】→【新增消费者】，抄下 API Key
3. 进模型详情 →【订阅】→ 选该 Consumer
4. 门户【HiChat】→ 选 `DeepSeek-32B` → 发「你好」
5. curl 复验：

```bash
curl http://<MODEL_GW_IP>:30080/v1/chat/completions \
  -H 'Host: model.example.internal' \
  -H 'Authorization: Bearer <API Key>' \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-32b","messages":[{"role":"user","content":"你好"}]}'
```

6. 管理员看【观测分析】应出现这次调用

第 6 步有记录 = 门户鉴权 → 网关 → 模型 全链路通。

### 6.9 Model 专属报错对照

| 现象 | 根因 | 处理 |
|---|---|---|
| Link API 列表空 | 路由不存在 / 实例未连 | 回 6.3 |
| 400 `model not found` | 三处模型名不一致 | 产品 Model、路由模型名、上游 id 统一 |
| 404 `no route` | 域名或路径不匹配 | 域名改 `*` 先验证 |
| `/v1/models` 返回 200，但 `/v1/chat/completions` 毫秒级 404 | ai-proxy 的 `openaiCustomUrl` 只写了前缀（如 `http://model-gw.example.internal/v1`），改写后上游收到 `/v1` | 见 6.3.8：把 provider 路径改成完整端点 `/v1/chat/completions` |
| 502/503 upstream | Pod 到 <MODEL_GW_IP>:32582 不通 | 安全组放通 Pod 网段 |
| 404 `can't find model server: xxx/yyy` | 上游是按模型名查找的推理路由（Kthena 等），传来的 model 名它不认识 | 用推理服务里**已注册的模型名**，如 `DeepSeek-R1-Distill-Qwen-32B`；或在路由「目标模型」里固定该名 |
| `no healthy upstream` | 上游集群**零端点**：DNS 类型来源解析失败，或路由引用的服务在注册表里不存在 | 换回固定地址来源（IP）；或给 CoreDNS 加 hosts 让域名可解析 |
| 浏览器直接访问 `IP:30080` 返回 404 | Host 与路由域名不匹配（不是配置错） | 用 `curl -H 'Host: <路由域名>'`，或本机 hosts 加域名 |
| 服务端口列显示 80 | 正常现象：固定地址的逻辑端口恒为 80 | 不用改，真实端口看「来源地址」里的 `:端口` |
| 401 | 没订阅 / Consumer Key 错；也可能是模型 Key 错 | 先看谁返回的：网关侧 401＝Consumer 问题；上游 401＝模型 Key 问题（看网关日志能区分） |
| 回答截断或超时 | 路由超时太小 | 调 300000ms |
| HiChat 提示模型不可用 | 参数没填 / 未订阅 / 非默认 Consumer | 补参数 + 订阅 + 设默认 Consumer |
| HiChat 报 `HTTP transport error during streaming: SSE/NDJSON stream failed: null` | **不是流式坏了**，是这次请求压根没返回 SSE（上游给了 404/401 的普通 JSON，或空 body），前端解析失败就是 null | 用同一条 curl 复现，看真实状态码：`model` 名错最常见（如发了产品展示名 `test1028` 而不是 `DeepSeek-R1-Distill-Qwen-32B`），上游回 `404 route not found`。改产品【模型配置】的 Model 字段，或在 AI 路由里加模型映射 |
| `404` + body `route not found` | 模型侧路由器按 model 名找不到对应的推理路由 | 与 `can't find model server` 同类：model 名必须与推理服务注册名逐字一致 |
| `Caused by: java.net.ConnectException: null`（message 为 null），栈顶是 `JdkHttpTransport` / `OpenAIException` | **TCP 都没连上**：HiChat 用「路由域名」当 base URL，而该域名在 `himarket-server` Pod 里解析不了（NIO 抛 `UnresolvedAddressException`，JDK 包成 message 为 null 的 ConnectException） | 见 6.9.1：给 `himarket-server` 加 `hostAliases`，或给 CoreDNS 加 hosts |

### 6.9.1 HiChat 的 `ConnectException: null`：请求没出集群，卡在 DNS

**判据（一看就分得清）**：

| 栈里最底层异常 | 含义 | 说明 |
|---|---|---|
| `java.net.ConnectException: null`（无 message） | **域名解析失败** | JDK HttpClient 里 `UnresolvedAddressException` 被包成 ConnectException，message 就是 null |
| `java.net.ConnectException: Connection refused` | 解析成功、端口没人听 | 域名对了但端口/DNS 指向错 |
| `HttpTransportException: SSE/NDJSON stream failed: null` 但**没有**底层 IO 异常 | 收到响应了，但不是 SSE（404/401 的 JSON） | 见 6.9 上一条，查 model 名或鉴权 |

**根因（源码 + 官方文档双证据）**：`AbstractLlmService.buildUri()` 里先取 AI 路由的 `domains`（优先非 `intranet`），`domain != null` 就用 `scheme://domain[:port]`，**只有当路由没有域名时才退回 `gatewayUris`（即导入实例时填的 Gateway 地址）**。官方 `USER_GUIDE_zh.md` 同义：「MCP Server 和 Model 默认使用域名进行访问，若未配置域名，则使用 Gateway 地址访问」。所以 HiChat 真正连的是 `http://<路由域名>/v1/chat/completions`，**该域名必须能被 `himarket-server` Pod 解析**。

**本次实测**：`himarket-server` 抛 `Caused by: java.net.ConnectException: null`，`at PlainHttpConnection.connectAsync`，说明 HiChat 拿到的 base URL 是 `http://ds32b-local.model.example.internal`（路由域名），而 `.example.internal` 这类型号是给**外部 DNS / 本机 hosts** 用的，集群内 CoreDNS 不认识它 → 连接都没建立 → 前端一路冒到 `SSE/NDJSON stream failed`。

**关键区别**：curl 成功、HiChat 失败，不是配置不一致，而是**发起方不同**——curl 从你的办公电脑发（Windows hosts 已加解析），HiChat 从 `himarket-server` Pod 里发（集群内没有这条 DNS）。

**修法一（最小、可回滚）：给 himarket-server 打 hostAliases**

```bash
# 网关 Service 的 ClusterIP（请求要在集群内回到这个网关，端口 80）
GIP=$(kubectl -n himarket get svc higress-gateway -o jsonpath='{.spec.clusterIP}'); echo "$GIP"

kubectl -n himarket patch deploy himarket-server --type merge -p "{
  \"spec\":{\"template\":{\"spec\":{\"hostAliases\":[
    {\"ip\":\"$GIP\",\"hostnames\":[\"ds32b-local.model.example.internal\"]}
  ]}}}}"

kubectl -n himarket rollout status deploy/himarket-server --timeout=180s
```

Java 走的是系统 resolver，会读 `/etc/hosts`，所以 `hostAliases` 对它是有效的（这点与 Envoy 不同，Envoy 用 c-ares 不读 hosts）。

**修法二（一次性、全局生效）：CoreDNS 加 hosts**

```bash
kubectl -n kube-system get cm coredns -o yaml > /tmp/coredns.bak.yaml
kubectl -n kube-system edit cm coredns
# 在 Corefile 里加一段（IP 换成网关 Service 的 ClusterIP）：
#     hosts {
#       172.19.x.x ds32b-local.model.example.internal
#       fallthrough
#     }
kubectl -n kube-system rollout restart deploy/coredns
```

好处是集群里所有 Pod 都能解析；坏处是改的是全局 DNS，改错了影响面大，动之前务必先备份 `/tmp/coredns.bak.yaml`。

**第二个坑：网关 Service 的端口可能不是 80**

HiMarket 拼 URL 时，若 domain 没有端口就用 **80**。而很多 Higress 安装的网关 Service 端口是 `30080`（`spec.ports[].port: 30080`），ClusterIP 上**根本没有 80**，于是 `Connection refused`。判据：

```bash
kubectl -n himarket get svc higress-gateway -o jsonpath='{.spec.ports[*].port}{" "}{.spec.clusterIP}{"\n"}'
# 输出形如 30080 30443 <HIMARKET_GW_IP> → ClusterIP:80 无人监听
```

**首选修法（本次实测采用，最简单）**：直接把 Service 的 `port` 改成 80/443，`targetPort` 和 `nodePort` 一律不动 —— 于是集群内走 `ClusterIP:80`，外部走 `节点IP:30080`，两条路同时成立。

```bash
kubectl -n himarket get svc higress-gateway -o yaml > /tmp/gw-svc.bak.yaml   # 备份

kubectl -n himarket patch svc higress-gateway --type json -p '[
  {"op":"test","path":"/spec/ports/0/port","value":30080},
  {"op":"replace","path":"/spec/ports/0/port","value":80},
  {"op":"test","path":"/spec/ports/1/port","value":30443},
  {"op":"replace","path":"/spec/ports/1/port","value":443}
]'

kubectl -n himarket get svc higress-gateway \
  -o jsonpath='{range .spec.ports[*]}{.name}={.port}->{.targetPort} nodePort={.nodePort}{"\n"}{end}'
# 期望：http2=80->80 nodePort=30080 / https=443->443 nodePort=30443
```

`test` 那句是保险：端口顺序或原值与预期不符时直接报错，不会改错字段。改动后 `PORT(S)` 显示为 `80:30080/TCP,443:30443/TCP`，`TCP_OK` 即通，**外部入口仍是 `:30080`，用法不变**。

**注意**：`LoadBalancer` 类型改端口会触发云 CLB 重建监听，VIP 一般不变，但外部入口会有几十秒抖动。若这套 Service 由 Helm 管理，命令行改动只是临时的，下次 `helm upgrade` 会按 chart 值改回去 —— 改通后要把 values 里的 `port: 80` 对齐（chart 本身通常就写 80，集群里是 30080 说明当初是按旧值部署的）。

**备选修法**（不想动原 Service）：新建一个只做端口转换的 ClusterIP Service（`port: 80` → `targetPort: 80`，selector 抄原 Service），路由域名指向它。

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: higress-gateway-http
  namespace: himarket
spec:
  type: ClusterIP
  selector:
    app: higress-gateway          # ← 换成原 Service 的真实 selector
  ports:
  - name: http
    port: 80
    targetPort: 80
EOF
kubectl -n himarket get endpoints higress-gateway-http    # 必须有地址，否则 selector 错了
```

之后 AI 路由域名用 `higress-gateway-http.himarket.svc.cluster.local`，HiMarket 拼出 `http://<该域名>/v1/...` 打 80 即可通。

**第三个坑：域名对了、端口通了，Host 还得让第二跳认**

HiChat 能用之后仍可能 `404` + `upstream_service_time: 2`。此时第一跳日志里 `authority` 就是 HiMarket 选中的那个域名，而它会被**原样转发**到第二跳（模型集群网关）——第二跳只认它自己域名列表里的名字，不认 svc 名。判据：`route_name` 正确、`upstream_host` 正确、耗时个位数毫秒、body 为空。

两个修法：

- **推荐**：路由域名用**模型侧已认可的真域名**（如 `ds32b-local.model.example.internal`），再给 `himarket-server` 打 `hostAliases` 把它指到网关 ClusterIP（此时 ClusterIP 已监听 80，能直接连），于是 HiChat 的 Host 天然是模型侧认识的那个，第二跳不需要任何改动。这一套同时满足「集群内可解析」「对外可调用」「不依赖会被冲掉的注解」。
- 应急：给路由加 `higress.io/upstream-vhost` 注解把 Host 改写回去，但门户每次保存都会清掉，只能当临时手段。

```bash
# hostAliases 指到网关 ClusterIP（端口 80 已由 Service 监听）
GIP=$(kubectl -n himarket get svc higress-gateway -o jsonpath='{.spec.clusterIP}')
kubectl -n himarket patch deploy himarket-server --type merge -p "{
  \"spec\":{\"template\":{\"spec\":{\"hostAliases\":[
    {\"ip\":\"$GIP\",\"hostnames\":[\"ds32b-local.model.example.internal\"]}
  ]}}}}"
```

**验证（改完必跑）**

```bash
# 1) Pod 内能否解析
kubectl -n himarket exec deploy/himarket-server -- sh -c 'getent hosts ds32b-local.model.example.internal || echo NO_DNS'

# 2) Pod 内能否连到网关 80
kubectl -n himarket exec deploy/himarket-server -- sh -c 'timeout 5 bash -c "cat </dev/null >/dev/tcp/ds32b-local.model.example.internal/80" && echo TCP_OK || echo TCP_FAIL'

# 3) 重开 HiChat 会话再问一句
```

> 注意：HiChat 的请求**不会**出现在网关日志的 5 分钟窗口里那些 `curl/` 或 `chatbox` 记录中——按 `user_agent` 找 Java 客户端那条才是它。找不到就说明它没到网关，直接去看 `himarket-server` 的异常栈。

### 6.9.2 HiChat 的 MCP / Skill 用不了：解析 tool 不是网关的活

现象：HiChat 发送普通对话 200，一旦发起带 MCP 工具/Skill 的会话就报 `SSE/NDJSON stream failed`、`Retries exhausted: 2/2`。网关日志里对应请求是 `500 / URX`，`upstream_service_time` 只有 2ms 量级。

**先纠正一个认知：链路上没有任何一层「该」解析 tool。**

| 层 | 职责 | 带 `tools` 时的行为 |
|---|---|---|
| HiChat（agentscope `HarnessAgent`） | 组装 `tools`、`tool_choice` 数组 | 正常发出 |
| Higress `ai-proxy` | 换路径、换 Host，body 原样透传 | 不碰 `tools`，A/B 对比中无 tools 200 / 带 tools 500 已证明与本层无关 |
| Kthena router（PD 分离） | 选 prefill/decode 实例、渲染 chat template、转发 | **不做 tool 解析**，只把模板渲染结果往下送 |
| vLLM | 唯一能把模型输出解析成结构化 `tool_calls` 的一层 | 未开开关时直接 400 拒绝受理 |
| 模型权重 | 唯一「会不会按格式吐 tool call」的一层 | 没训练过就不会 |

**两处报错的真实机理**

1. **vLLM 返回 400**：vLLM 的准入规则——请求体出现 `tools` 且 `tool_choice` 未显式设为 `none`，而服务启动时没带 `--enable-auto-tool-choice` + `--tool-call-parser`，就在 API 入口 400 掉，**模型一个 token 都没生成**。这不是解析失败，是拒绝受理。
2. **Kthena router 返回 500 / 2ms**：router 在转发前要先渲染 chat template（把 `messages` + `tools` 套成 prompt）。它拿到的模板是 DeepSeek-R1-Distill 的 ChatML 模板，**模板里没有 tools 分支**，渲染阶段即异常。2ms 这个数字本身就是判据：模型推理不可能 2ms 出结果，说明死在预处理，请求没进 prefill。

**模型层面的硬约束（决定性）**

`DeepSeek-R1-Distill-Qwen-32B` 的模型卡明确声明**不支持 tool calling**：蒸馏过程覆盖掉了基座 Qwen2.5 的 tool-call 微调。所以把 vLLM 参数全开也只是「不报错了」，吐出来的 `tool_calls` 不按格式、参数靠编，**不能用于生产**。要用工具调用，得换原生 tool-trained 模型：`Qwen3-32B-Instruct`、`Qwen2.5-32B-Instruct`、`DeepSeek-V3`、`Llama-3.3-70B-Instruct`。

**生产环境的正确配法：按能力分池，而不是在网关上兜**

1. **能力登记表**。每个模型上线时登记 `tool_calling`（true/false）、`context`、`parser`、`chat_template` 是否有 tools 分支。这张表决定它能不能挂到 Agent / MCP 场景。
2. **两类模型池**。纯对话/推理池（R1-Distill 这类）只给「纯对话」产品用；Agent 池（tool-trained）给 HiChat + MCP / Skill 用。HiMarket 侧就是**建两个 Model API 产品**，在 Usage Guide 里写清能力标签，开发者按场景订阅。
3. **vLLM 启动参数标准化**（写进 Helm values 或模型部署 CR，不要手工 patch Pod）：

```yaml
args:
  - --model=/models/deepseek-r1-distill-qwen-32b
  - --tensor-parallel-size=4
  - --enable-auto-tool-choice
  - --tool-call-parser=hermes        # 必须与模型 chat template 的格式匹配
  # 模板本身缺 tools 分支时才需要显式覆盖：
  # - --chat-template=/templates/qwen-tool-use.jinja
```

parser 与模型的对应关系：Qwen 系（含 Qwen3）→ `hermes`；Llama 3.1/3.3 → `llama3_json`；Mistral → `mistral`；DeepSeek-V3 → `deepseek_v3`（以所装 vLLM 版本的 `--help` 为准，版本间有增删）。

4. **PD 分离的额外要求**：prefill 与 decode 两侧的镜像版本、启动参数、tokenizer/chat template **必须完全一致**。任一侧模板不同，router 渲染出的 prompt 与引擎预期不符，同样表现成带 tools 就 500。
5. **网关只做鉴权、限流、路由、观测，不做语义改写**。用 transformer 插件剥 `tools` 只是让报错消失：多轮里 `role:"tool"` 的结果无法回传，模型变成「假装用了工具」，反而更难排查。

**上线前回归四件套（缺一不可）**

```bash
# ① 不带 tools：应为 200
curl -s -o /dev/null -w '%{http_code}\n' http://<模型路由域名>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<name>","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'

# ② 带 tools：应为 200，且响应含 choices[0].message.tool_calls
curl -s http://<模型路由域名>/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"<name>",
  "messages":[{"role":"user","content":"北京天气怎么样"}],
  "tools":[{"type":"function","function":{"name":"get_weather","description":"查天气",
    "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]
}'

# ③ 带 tools + stream=true：应为 200，且能收到 tool_calls 的增量帧
# ④ 回传 tool 结果：messages 里追加 {"role":"tool","content":"..."}，应正常续答
```

四条全绿才能挂到 Agent 场景。②的 400 响应体通常会直接点明原因（`auto tool choice requires --enable-auto-tool-choice ...`），比翻引擎日志快得多。

### 6.9.3 换成支持 tool 的模型：选型与启动参数

**先看官方的反面证据，别再试图修 R1-Distill**

| 证据 | 原文/结论 |
|---|---|
| 官方 README 基座表 | `DeepSeek-R1-Distill-Qwen-32B` ← `Qwen2.5-32B`（**base**，非 Instruct，本身无 tool 能力） |
| 官方 README 第 7 节 | finetuned with **800k samples curated with DeepSeek-R1**（纯推理样本，无 tool call 数据） |
| 官方 README 第 6 节 vLLM 命令 | 只有 `--tensor-parallel-size / --max-model-len / --enforce-eager`，**无 tool 开关** |
| 阿里云百炼能力表 | Function Calling **不支持**、结构化输出 **不支持** |

注意：同系列 `Distill-Llama-70B` 的基座是 `Llama-3.3-70B-Instruct`（本来有 tool 能力），蒸馏后才是「被覆盖丢失」；Qwen-32B 是「从来就没有」。两者的补救路径相同。

**候选模型（按替换成本排序）**

| 模型 | 规模/显存 | parser | 特点 | 适用 |
|---|---|---|---|---|
| **Qwen3-32B** | 32B 稠密 / bf16 约 64GB，TP=4 每卡 ~16GB | `hermes` + `qwen3` | 与现有 32B 同规模，TP=4 直接复用；中文强；Apache 2.0 | **首选** |
| **Qwen2.5-32B-Instruct** | 同上 | `hermes` | 非 thinking，模板与工具调用最成熟，链路最短 | 想少踩坑时选它 |
| Qwen3-30B-A3B-Instruct | MoE 30B 总参 / 3B 激活 | `hermes` | 吞吐高 3-5 倍，但需能放下全部专家权重 | 高并发 |

不建议：`DeepSeek-V3/V4` 等 MoE 旗舰（671B 级，现有 4 卡放不下）。

**下载（内网走 ModelScope）**

```bash
pip install -U modelscope
modelscope download --model Qwen/Qwen3-32B --local_dir /mnt/nfs-temp/models/Qwen3-32B
# 或
git lfs clone https://www.modelscope.cn/Qwen/Qwen3-32B.git /mnt/nfs-temp/models/Qwen3-32B
```

**vLLM 启动参数（Qwen3-32B，vLLM ≥ 0.9 写法）**

```bash
vllm serve /mnt/nfs-temp/models/Qwen3-32B \
  --served-model-name qwen3-32b \
  --tensor-parallel-size 4 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.90 \
  --enable-prefix-caching \
  --enable-auto-tool-choice --tool-call-parser hermes \
  --reasoning-parser qwen3
```

- `--enable-reasoning` 在 0.9 之后已由 `--reasoning-parser` 承担，不要再写。
- `--reasoning-parser` 必须写 `qwen3`。抄 Qwen 文档写成 `deepseek_r1` 会导致回复内容为空（全部落进思考段）。
- 已有 `--enforce-eager` 的旧命令建议去掉，它关掉 CUDA Graph，吞吐掉两成以上。

**Agent 场景建议关掉思考链**：HiChat 的 agentscope 客户端不认 `reasoning_content`，开思考只会让首字延迟变长。请求里加：

```json
"chat_template_kwargs": {"enable_thinking": false}
```

或在 HiMarket 的模型适配里把该参数固化为默认。

**Kthena PD 分离要同步改两处**：prefill 与 decode 两个角色的镜像 tag、`args`、模型路径必须完全一致（含 `--tool-call-parser`）。只改一侧会出现「算出的长度与引擎实际不符」，表现为调度异常或带 tools 就 500。

**换完的验收顺序**：6.9.2 的四件套 → HiChat 新建会话发一句普通对话 → 挂一个 MCP 工具再发一句 → 看到 `tool_calls` 往返即通。


### 6.10 接入外部 API Key（OpenRouter / 国内厂商等）

只要对端是 OpenAI 兼容接口，HiMarket 侧**零改动**，只是多一条 AI 路由。真正的门槛是两件事：**集群能不能出网**、**额度够不够用**。

**6.10.1 先测出网（顺序不能反）**

```bash
# ① DNS：Pod 内能否解析
kubectl -n himarket exec deploy/higress-console -- getent hosts openrouter.ai

# ② HTTPS 连通：尽量从 Pod 内测
kubectl -n himarket run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c 'wget -qO- -T8 https://openrouter.ai/api/v1/models | head -c 200'

# ③ 镜像拉不到时的兜底：节点侧测（多数 CNI 出网走同一 SNAT）
curl -s -m 8 -o /dev/null -w '%{http_code}\n' https://openrouter.ai/api/v1/models
```

②或③返回 200/401 才算通；`000`、`timeout`、`no such host` 说明这条路不存在，直接跳到 6.10.5。

**6.10.2 通了就按这张表配**

| 字段 | 值 |
|---|---|
| 服务来源类型 | 固定地址 |
| 地址 | `openrouter.ai:443` |
| 协议 | **HTTPS**（不是 HTTP） |
| 路由名称 | `openrouter` |
| 域名 | `model.example.internal`（与自建模型共用，靠路径区分）或新起一个 |
| 路径 | `/v1/chat/completions` |
| Provider | OpenAI 兼容 |
| 自定义上游地址 | `https://openrouter.ai/api/v1/chat/completions`（**路径必须带上 `/api`**，否则 404） |
| API Key | `sk-or-v1-...` |
| 模型映射 | `*` → `deepseek/deepseek-chat-v3-0324:free`（见 6.10.3 的用法） |
| 超时 | `300000` ms |

关键差异：OpenRouter 的上游路径是 `/api/v1/chat/completions`，而客户端（HiChat / SDK）打的是 `/v1/chat/completions`。两者不一致，必须靠「自定义上游地址」或路径重写来对齐，否则表现为「路由建好了但一直 404」。

**6.10.3 模型名建议用 `*` 兜底映射**

OpenRouter 的模型 id 形如 `deepseek/deepseek-chat-v3-0324:free`，带斜杠和 `:free` 后缀，且免费名单每周变动。建议：

- 路由里配 `模型映射`：`*` → 当前免费模型 id
- HiMarket 产品里的 Model 填一个稳定的短名，如 `openrouter-free`

这样免费模型下线时，只改网关一处，门户产品不用动，开发者也不用重新订阅。

**6.10.4 免费额度的真实数字**

| 条件 | 每分钟 | 每天 |
|---|---|---|
| 从未充值 | 20 次 | **50 次** |
| 累计充值过 $10（一次性，不需保持余额） | 20 次 | 1000 次 |

免费模型只有约 25~29 个，且名单每周变动。按这个量级：**够做演示和联调，不够给一个门户的多人用**——50 次/天，两个人在 HiChat 里聊几轮就没了，而且失败请求也计入。

**6.10.5 出网不通时的三条替代路**

| 方案 | 做法 | 适用 |
|---|---|---|
| 内网反向代理（推荐） | 在能出网的机器上跑 nginx：`location / { proxy_pass https://openrouter.ai/api/v1/; }`，网关上游改填这台机器的内网 IP:端口，协议 HTTP | 集群完全无外网，但有台跳板机能出网 |
| 换国内厂商 | 阿里百炼 / 硅基流动 / 智谱 等，同样 OpenAI 兼容，域名在国内、延迟低、**数据不出境** | 合规敏感场景 |
| 纯内网自建 | 沿用 6.2~6.8，多部署一个模型就多一条路由 | 数据绝对不能出内网 |

注意：Envoy（higress-gateway）**不读取 `http_proxy` 环境变量**，给 Pod 注入代理是无效的。要有代理，只能在网关前面放一个内网 nginx 做转发。

**6.10.6 合规提醒**

把内网数据发到境外 API 属于数据出境。生产环境使用前需走单位的数据出境/安全审批；POC 阶段也建议只用公开、非敏感语料验证链路，别拿真实业务数据试。

### 6.11 一页验收清单

**模型侧（第二个集群）**

- [ ] `curl :30081/v1/models`（带 `Host: model-gw.example.internal`）返回 model id
- [ ] `curl :30081/v1/chat/completions`（带 `Host: model-gw.example.internal`）返回 choices
- [ ] 模型侧 AI 路由的域名列表里有 himarket 侧使用的那个域名（如 `ds32b-local.model.example.internal`）

**himarket 侧（第一跳）**

- [ ] Higress 服务来源里有 `<MODEL_GW_IP>:30081`，`.static` 服务名解释到它
- [ ] AI 路由已启用，超时 300s，路由域名只留一个（多域名时 HiMarket 只取第一个非 intranet，选哪个不由你控制）
- [ ] 路由的 `upstream-vhost` 注解为空时打网关仍返回 choices（= 不依赖会被门户冲掉的注解）
- [ ] `curl http://<节点IP>:30080/v1/chat/completions -H 'Host: <路由域名>'` 返回 choices，耗时秒级（个位数毫秒 = Host/路由不对）
- [ ] `kubectl -n himarket get svc higress-gateway` 的 `PORT(S)` 含 **80**（`80:30080/TCP`）。只是 30080 的话，HiChat 一定 `Connection refused`
- [ ] `himarket-server` Pod 内 `getent hosts <路由域名>` 能返回网关 ClusterIP（否则 HiChat 报 `ConnectException: null`）
- [ ] Pod 内 `curl http://<路由域名>/v1/chat/completions`（**不带端口**）返回 `200` —— 这一条同时验证解析、80 端口、路由 Host、模型侧 Host 四项

**门户侧**

- [ ] HiMarket 产品状态 = 已发布
- [ ] Link API 已关联
- [ ] 产品【模型配置】的 Model = 推理服务注册名逐字一致（填展示名会得到 `404 route not found`）
- [ ] 开发者已订阅，HiChat 有回复（**务必点「新会话」**，旧会话缓存着创建时的 baseUrl）
- [ ] 观测分析看到调用记录

**一次典型的成功响应**（可作为对照基线）：

```json
{"id":"chatcmpl-...","object":"chat.completion","model":"DeepSeek-R1-Distill-Qwen-32B",
 "choices":[{"index":0,"message":{"role":"assistant","content":"..."},"finish_reason":"length"}],
 "system_fingerprint":"vllm-0.22.1-tp4-...","usage":{"prompt_tokens":6,"completion_tokens":10}}
```

看到 `system_fingerprint: vllm-...` 就说明是模型真正生成的，不是网关伪造的。
