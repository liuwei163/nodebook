# 工作空间文件索引

> 共 **28 个文件**、约 **10,150 行**，按用途分为五个域。
> 最近整理：2026-11-12（删掉 4 个被取代的旧文件，独有内容已并入权威版本，见第 6 章）。
> 新增文件时请同步更新对应分区的表格，否则这份索引会很快失效。

---

## 0. 速览

| 域 | 文件数 | 行数 | 状态 |
|---|---|---|---|
| 一、系统部署（把 HiMarket 装起来） | 10 | 2,452 | 已完成，可复现 |
| 二、配置过程 · 跨集群接入模型 | 4 | 1,549 | 已验收 |
| 三、配置过程 · MCP 接入 | 5 | 1,562 | 直连已验收，Nacos 路径失败 |
| 四、生产化方案 | 5 | 1,446 | 设计完成，未落地 |
| 五、运维与排障 | 3 | 3,106 | 持续维护 |
| 索引（本文件） | 1 | 268 | — |
| **合计** | **28** | **约 10,383** | |

按类型分布：

| 类型 | 数量 | 说明 |
|---|---|---|
| Markdown 文档 | 11 | 手册、Runbook、复盘、操作指南 |
| Shell 脚本 | 8 | 离线打包、镜像搬运、自检、验证 |
| K8s YAML | 7 | 部署清单、PV、Ingress、McpBridge |
| Python | 1 | MCP 服务端（单文件，py2/py3 双兼容） |
| Dockerfile | 1 | 生产镜像定义 |

> 每个域只有一个「权威版本」。如果两份文档讲同一件事，保留最新且经过实测的那份——**不要靠日期猜，看有没有实测输出**。

---

## 一、系统部署域

**目标**：在离线 / 内网环境把 HiMarket v0.8.2 完整部署起来。

| 文件 | 类型 | 行数 | 作用 | 状态 |
|---|---|---|---|---|
| `HiMarket-离线部署手册-可复现版.md` | 文档 | 952 | **权威版本**。逐命令还原实际部署，含 28 个坑的现场解法、预期输出、验收清单、升级回滚（部署期之外的运行期坑见 `部署问题排查记录` 坑-29/30） | 已验收 |
| `离线物料清单.md` | 文档 | 336 | BOM：版本矩阵、要下载的文件、11 个镜像、资源占用、端口清单；附录 A 软件前置、附录 B 10 个工作负载 | 已使用 |
| `HiMarket-K8s部署手册.md` | 文档 | 309 | **在线部署**参考（能访问公网 registry）。价值是讲清 install.sh 内部机制与三套版本号；开头列了它与离线实际的 4 处结论差异 | 参考 |
| `fetch-offline-bundle.sh` | 脚本 | 216 | 摆渡机（有外网）一键打包：源码 + helm + chart + 镜像 tar + SHA256 | 已使用 |
| `mirror-himarket-images.sh` | 脚本 | 94 | 摆渡机侧：`helm template` 渲染抓全部 image 引用，逐个 pull 后 `docker save` | 已使用 |
| `import-to-harbor.sh` | 脚本 | 117 | 内网侧：`docker load` → 替换 registry host → retag → push Harbor | 已使用 |
| `prepare-internal.sh` | 脚本 | 185 | 内网操作机：校验离线文件、装 helm、改 `install.sh` 里写死的公网 registry 与 tag | 已使用 |
| `preflight-check.sh` | 脚本 | 128 | 部署前 12 项自检，只读不改集群，输出 PASS/FAIL 表 | 已使用 |
| `k8s/local-storage-pv.yaml` | YAML | 77 | 静态 PV。集群只有 `local-storage`（no-provisioner），不预建则 mysql/sandbox 的 PVC 永久 Pending | 已使用 |
| `k8s/nacos-ingress.yaml` | YAML | 38 | Nacos 控制台经 Higress + CLB 对外暴露 | 已使用 |

**执行顺序**：`离线物料清单.md`（备料）→ `fetch-offline-bundle.sh` → 摆渡 → `import-to-harbor.sh` → `prepare-internal.sh` → `preflight-check.sh` → `local-storage-pv.yaml` → `nacos-ingress.yaml` → 照 `可复现版` 走 `install.sh`

**一句话记忆**：镜像变量改 `install.sh`（改 values/env 都无效）；SA 要逐个 patch 再删 Pod；PVC 要手工建 PV。

---

## 二、配置过程 · 跨集群接入模型

**目标**：把模型集群的 Qwen3-32B 接入 HiMarket 集群，在 HiChat 里可用。

| 文件 | 类型 | 行数 | 作用 | 状态 |
|---|---|---|---|---|
| `HiMarket-跨集群接入模型-全流程配置手册.md` | 文档 | 1,058 | **权威版本**。六阶段主手册：三个"名字"辨析、取值清单、七级验收、16 条故障速查、**10.2 输出截断与 `<think>` 泄漏的三层判定**、变更回滚、附录实测参数 | 已验收 |
| `k8s/qwen3-32b-modelserving.yaml` | YAML | 210 | Kthena ModelServing，昇腾 910×8、TP=8、共置单角色。**生产路径** | 已使用 |
| `k8s/vllm-qwen3-32b-deploy.yaml` | YAML | 172 | 裸 Deployment。**仅排障用**，用于隔离"是不是 Kthena 的问题" | 排障工具 |
| `k8s/test-qwen3.sh` | 脚本 | 109 | 四步验证：模型名 → 普通对话 → tool calling → 多轮回传 | 已使用 |

**关键结论**（已写入手册）：域名用点号 `qwen3.32b.example.internal`，模型名用横线 `qwen3-32b`，混用直接 404；两个集群的 Higress 路由可写同一域名，但 `himarket-server` 需要 hostAliases 指向网关 ClusterIP；`openaiCustomUrl` 必须填到 `/v1/chat/completions` 完整端点。

---

## 三、配置过程 · MCP 接入

**目标**：让 HiChat 能调用自建 MCP 工具。

| 文件 | 类型 | 行数 | 作用 | 状态 |
|---|---|---|---|---|
| `k8s/mini-mcp/RUNBOOK-从零建MCP.md` | 文档 | 367 | **直连方式全流程**：部署 → 两层验证 → 建产品 → 填地址 → 刷新工具 → 发布订阅 | **已验收可用** |
| `k8s/mini-mcp/复盘-Nacos接入MCP全流程.md` | 文档 | 537 | Nacos 侧完整流程（可独立复用）+ HiMarket 失败根因 + 网关链路验证与回滚 | **失败记录，价值最高** |
| `k8s/mini-mcp/mini_mcp_py2.py` | Python | 469 | **当前在用**。零依赖、py2/py3 双兼容，同时支持 Streamable HTTP（`/mcp`）与 SSE（`/sse`） | 运行中 |
| `k8s/mini-mcp/mini-mcp.yaml` | YAML | 146 | 部署清单：ConfigMap + Deployment + ClusterIP Service，镜像 `kubeflow/python:3.7` | 运行中 |
| `k8s/mini-mcp/test-mini-mcp.sh` | 脚本 | 43 | 七步 MCP 协议握手自测（initialize / tools/list / get_time / echo / 405） | 已使用 |

**两条路径的结论**：

| 路径 | 结果 | 依据 |
|---|---|---|
| 自定义直连（产品里手填 URL） | 可用 | 已实测工具执行成功 |
| 从 Nacos 服务发现导入 | 不可用 | 连接点固定 `transport=stdio` 且无 `url`，改 Nacos 协议类型/重同步/重导入均无效 |
| 从网关导入 | 未验证 | 需要先 patch mcpbridge 白名单，步骤见复盘 9.1 |

**关键区分**：工具列表显示 3 个来自 Nacos 快照，不能证明 HiMarket 连通过 mini-mcp。工具走快照路径，连接点走装配逻辑，两者独立。

---

## 四、生产化方案

**目标**：把 PoC 形态的 MCP 改造成可运维的生产形态。**设计已完成，尚未在任何环境执行。**

| 文件 | 类型 | 行数 | 作用 | 状态 |
|---|---|---|---|---|
| `k8s/prod-mcp/README-生产级MCP全链路手册.md` | 文档 | 578 | 六阶段手册：架构决策、每步原理、七层验证矩阵、Nacos/Higress 概念速查 | 未落地 |
| `k8s/prod-mcp/02-mcp-server-prod.yaml` | YAML | 398 | SA + Service(sessionAffinity) + Deployment(2 副本/三类探针/PDB/HPA/NetworkPolicy) + 注册器 sidecar | 未落地 |
| `k8s/prod-mcp/03-higress-mcpbridge-prod.yaml` | YAML | 225 | McpBridge 新增 `company-nacos-ai` registry + key-auth + cluster-key-rate-limit 插件 | 未落地 |
| `k8s/prod-mcp/nacos-register.sh` | 脚本 | 187 | Nacos 注册器 sidecar：鉴权、心跳、健康自愈摘除、SIGTERM 注销 | 未落地 |
| `k8s/prod-mcp/Dockerfile` | Dockerfile | 58 | 自建镜像：非 root(10001)、预编译字节码、HEALTHCHECK | 未落地 |

**落地前置条件**（四个都缺一不可）：

1. 能往 Harbor 推自建镜像
2. Nacos 有建 `ai-mcp` 命名空间的权限
3. 有可用的 `mcp-prod.example.internal` 域名解析
4. 有 Redis（限流插件依赖）

**为什么不直接上生产方案**：`03-higress-mcpbridge-prod.yaml` 是整体声明式的，`apply` 会覆盖整个 `registries` 数组。执行前必须先 `kubectl get mcpbridge default -o yaml > backup.yaml` 备份。

---

## 五、运维与排障

| 文件 | 类型 | 行数 | 作用 | 状态 |
|---|---|---|---|---|
| `HiMarket-管理员与开发者操作手册.md` | 文档 | 1,860 | 平台功能操作：管理员建产品/门户/订阅审批，开发者浏览/订阅/HiChat 使用；第六章是 Model API 专题的排查推演 | 参考 |
| `HiMarket-部署问题排查记录.md` | 文档 | 1,073 | **30 个坑的完整记录**，按现象归类，编号与可复现版的 `⚠️ 坑-NN` 一一对应。第八章专讲「能对话之后」的输出异常（坑-29 `<think>` 泄漏、坑-30 改错层）。**遇到问题先查这份** | 持续维护 |
| `HiMarket-部署完成记录与运维手册.md` | 文档 | 173 | 本次部署的 as-built 快照：最终架构、组件资源、日常运维约定、账号 | 已验收 |

---

## 六、2026-11-12 整理记录（删了 4 个，补录 2 条结论）

判断标准：**同一件事只留一个权威版本，以"有实测输出 + 日期更新"为准；独有内容先并入再删。**

| 删除的文件 | 行数 | 被谁取代 | 独有内容去哪了 |
|---|---|---|---|
| `HiMarket-离线部署Runbook.md` | 539 | `可复现版`（同主题，晚 2 天，含 28 个实测坑） | 集群外软件清单、10 个工作负载表 → 并入 `离线物料清单.md` 附录 A/B |
| `k8s/RUNBOOK-跨集群接入Qwen3.md` | 323 | `跨集群接入模型-全流程配置手册.md`（晚 11 分钟，是它的整理版） | Ingress 被禁时的 McpBridge `type: dns` + `destination` 注解写法 → 并入主手册 3.4 备选方案 |
| `k8s/mini-mcp/RUNBOOK-接入Nacos与Higress.md` | 227 | `复盘-Nacos接入MCP全流程.md`（晚 6 小时，含失败根因） | 网关代理验证命令、平行产品对照、回滚步骤 → 并入复盘 9.1 |
| `k8s/mini-mcp/mini_mcp.py` | 187 | `mini_mcp_py2.py`（功能超集：py2 兼容 + SSE） | 无（纯子集），删除避免有人照着它改再踩一次 Python 2.7 的坑 |

**特别注意 Runbook 为什么必须删**：它在「阶段四」写的是「改 `values.yaml` 才是可靠路径」，而实际部署证明**改 values 完全不生效**（`install.sh` 会 `unset` 变量并用 `--set` 覆盖）。留着它等于留下一份会把人带进坑的指导，这不属于"有价值的差异"，属于错误。

删除前已备份到 `.workbuddy/archive/2026-11-12-dedup/`，需要考古随时可取。

### 有意保留的重叠

| 重叠 | 为什么不合并 |
|---|---|
| `管理员与开发者操作手册` 第六章 ↔ `跨集群接入模型手册` | 前者是"界面怎么点 + 当时怎么推出来的"（含 `route_name` 定位抢路由、`ConnectException` 的 DNS 根因），后者是"六阶段 + 七级验收"的结构化流程。**执行看后者，卡住查前者** |
| `离线物料清单` ↔ `可复现版` 第 1 章 | 一个答"要准备什么"，一个答"怎么一步步装"，阶段不同，合起来反而难查 |
| `部署完成记录` ↔ `可复现版` 第 9/10 章 | 前者是 as-built 快照（现在是什么样），后者是 how-to（当初怎么做的）。环境变更时改前者，流程改进时改后者 |

### 补录：此前只存在于对话里的两条结论

这两条是跨集群链路打通之后才暴露的，原先没有落到任何文档，现在补进去了：

| 结论 | 落在哪 | 要点 |
|---|---|---|
| `<think>` 泄漏 / 回复说到一半就断，根因是**产品层「最大输出 Tokens」=500** | 主手册 **10.2**、参数表 3.2 注解、速查表 3 行；排查记录 **坑-29** | 限制输出有**三层**：HiMarket 产品（`max_tokens`）、vLLM `--max-model-len`、`--max-num-batched-tokens`（无关）。最容易忽略的是第一层，因为它在界面上而不是启动参数里 |
| `--reasoning-parser qwen3` 在标签未闭合时**静默失效** | 主手册 3.2 注解；排查记录 **坑-30** | 它是"搬运工"不是"开关"：不改变模型是否输出 `<think>`，只在生成完之后按成对标签切分。单边标签 → 切不出来 → 整段当正文，**不报错、不打日志** |

配套的判定捷径也写进去了：**同一个模型、同一套 vLLM 参数，直连客户端不截断、经 HiMarket 就截断 → 100% 是产品层配置**。

---

## 七、按场景的推荐阅读顺序

### 场景 A：新人接手

```
HiMarket-部署完成记录与运维手册.md   ← 先看现状，10 分钟
  ↓
HiMarket-管理员与开发者操作手册.md   ← 平台怎么用
  ↓
HiMarket-部署问题排查记录.md         ← 遇到问题查这里
```

### 场景 B：重新部署一套

```
离线物料清单.md                       ← 备料，附录 A/B 是前置条件
  ↓
fetch-offline-bundle.sh → import-to-harbor.sh → prepare-internal.sh
  ↓
preflight-check.sh（12 项全 PASS 再继续）
  ↓
k8s/local-storage-pv.yaml → k8s/nacos-ingress.yaml
  ↓
HiMarket-离线部署手册-可复现版.md（照着走，别跳第 4 章）
```

### 场景 C：接入新模型

```
HiMarket-跨集群接入模型-全流程配置手册.md   ← 主手册，六阶段
  ↓
k8s/qwen3-32b-modelserving.yaml            ← 改模型路径/服务名后 apply
  ↓
k8s/test-qwen3.sh                          ← 四步验证
  ↓
卡住 → 管理员手册第六章（有当时的推演过程）
```

### 场景 D：接入新 MCP

```
k8s/mini-mcp/RUNBOOK-从零建MCP.md          ← 直连方式，已验证可用
  ↓
改 mini_mcp_py2.py 的 TOOL_DEFS / TOOL_IMPL
  ↓
kubectl create configmap ... + rollout restart
  ↓
k8s/mini-mcp/test-mini-mcp.sh              ← 七步握手
```

要走网关或注册中心，先读 `复盘-Nacos接入MCP全流程.md` 第 5、6 章——那里记录了「从 Nacos 导入」为什么走不通，能省掉几小时试错。

### 场景 E：MCP 要上生产

```
k8s/prod-mcp/README-生产级MCP全链路手册.md
```

前提是四个前置条件都能满足。满足不了就停在直连形态，先解决可用性再谈治理。

---

## 八、文件依赖关系

```
                    ┌──────────────────────────────────────┐
                    │  一、系统部署（10 个文件）            │
                    │  物料清单 → 离线包 → Harbor → PV → 装 │
                    └───────────────────┬──────────────────┘
                                        │ 产出 himarket-server / Higress / Nacos
                    ┌───────────────────┴───────────────────┐
                    ↓                                       ↓
    ┌───────────────────────────────┐     ┌───────────────────────────────┐
    │ 二、跨集群接入模型（4 个）     │     │ 三、MCP 接入（5 个）           │
    │ ModelServing → Higress → 产品  │     │ mini-mcp → 产品 → HiChat       │
    └───────────────┬───────────────┘     └───────────────┬───────────────┘
                    │                                     │
                    └──────────────────┬──────────────────┘
                                       ↓
                    ┌──────────────────────────────────────┐
                    │ 四、生产化方案（5 个，未落地）        │
                    │ 自建镜像 + 独立命名空间 + 鉴权限流     │
                    └──────────────────┬───────────────────┘
                                       ↓
                    ┌──────────────────────────────────────┐
                    │ 五、运维与排障（3 个）                │
                    │ 操作手册 + 故障库 + 部署快照           │
                    └──────────────────────────────────────┘
```

---

## 九、维护约定

| 事项 | 约定 |
|---|---|
| 新增手册 | 先问「是不是已有文档的子集」。是子集就别新建，补进权威版本 |
| 同一主题两份文档 | 只允许「执行版 + 推演版」这种定位差异；内容若冲突，以有实测输出的为准，另一份立刻改或删 |
| 脚本改动 | 在脚本头部注释里写明改动原因，不要只改代码 |
| 配置变更 | 变更前 `kubectl get <资源> -o yaml > backup.yaml`，变更后回读确认 |
| 失败实验 | 也写进文档。价值最高的部分是「哪条路走不通、为什么」，不是「哪条路走通了」 |
| 弃用文件 | **不在工作区里保留**。先备份到 `.workbuddy/archive/<日期>/`，再从工作区删除，并在第 6 章登记 |
| 删任何文件前 | 先 grep 全库引用，确认没有文档指向它 |

---

## 十、脱敏占位符对照表（2026-11-13）

全部文档已做脱敏，真实域名 / IP / 节点名 / 口令已替换为占位符。
读文档时看到尖括号占位符，按下表填自己的环境值：

### 域名

| 占位符 | 含义 | 原值形态 |
|---|---|---|
| `harbor.example.internal` | 私有镜像仓库 Harbor | `harbor.<公司域名>` |
| `himarket.example.internal` | HiMarket 前台 / 门户 | `himarket.<公司域名>` |
| `himarket-admin.example.internal` | HiMarket 管理后台 | `himarket-admin.<公司域名>` |
| `himarket.model.example.internal` | HiMarket 侧的模型路由域名 | `himarket.model.<公司域名>` |
| `model.example.internal` | 通用模型路由域名 | `model.<公司域名>` |
| `qwen3.32b.example.internal` | Qwen3-32B 对外路由域名（**点号**，与模型名的横线不同） | `qwen3.32b.<公司域名>` |
| `qwen3-32b.model.example.internal` | Qwen3-32B 在 model 域下的变体 | `qwen3-32b.model.<公司域名>` |
| `ds32b-local.model.example.internal` | DeepSeek-32B 本地部署路由 | `himarket-dp32blocal.model.<公司域名>` |
| `mcp.example.internal` | MCP 聚合域名（存量 registry 用） | `mcp.<公司域名>` |
| `mcp-prod.example.internal` | MCP 生产域名（AI 专用 registry 用） | `mcp-prod.<公司域名>` |
| `nacos.example.internal` | Nacos 控制台域名 | `nacos.<公司域名>` |
| `model-gw.example.internal` | 模型集群侧网关的 Host 名 | `ds.local.com` 一类内网名 |
| `coding-plan.example.internal` | AI 编码服务 | `llm-coding-plan.internal` |

### IP 与网络

| 占位符 | 含义 |
|---|---|
| `<HIMARKET_GW_IP>` | HiMarket 集群 higress-gateway 的 ClusterIP / LB |
| `<MODEL_GW_IP>` | 模型集群 higress-gateway 的节点 IP（NodePort 外部访问） |
| `<MINI_MCP_IP>` | mini-mcp Service 的 ClusterIP |
| `<HIGRESS_CONSOLE_IP>` | higress-console 的 ClusterIP |
| `<HIGRESS_CTRL_IP>` | higress-controller 的 ClusterIP |
| `<CODING_PLAN_IP>` | AI 编码服务地址 |
| `<CORP_PROXY_IP>` | 公司 HTTP 代理 |
| `<JUMPHOST_IP>` | 跳板机 / 操作机 |
| `<WSL_HOST_IP>` · `<WSL_SUBNET>` | 本地 WSL 构建环境 |
| `<K8S_SERVICE_CIDR>` | 集群 Service 网段 |

### 其他

| 占位符 | 含义 |
|---|---|
| `<MODEL_CLUSTER_NODE>` · `<HIMARKET_NODE_MASTER>` · `<HIMARKET_NODE_WORKER1/2>` | 各集群节点名 |
| `<HIGRESS_PASSWORD>` | Higress / Nacos / MySQL 共用口令 |
| `ai-platform` | Harbor 里的项目名（原 `ai-platform-poc`） |
| `ai-route-coding.internal` | 曾抢走 host 的那条编码路由（原含项目代号） |
| `demo-test` | 示例产品名 |

> **保留未脱敏的**：`127.0.0.1` / `0.0.0.0` 等回环地址、`*.himarket.svc.cluster.local` 等 k8s 集群内部 DNS、
> `higress.io` / `kubernetes.io` / `github.com` / `aliyuncs.com` 等公开域名、公共镜像仓库地址。
> 这些不含环境特征，且删掉会让命令失去可执行性。

**回滚与清理**：

| 备份 | 位置 | 内容 |
|---|---|---|
| 工作区文件 | `.workbuddy/archive/pre-desensitize-20261113.tar.gz` | 全部 md/yaml/sh/py 脱敏前原文 |
| memory 与归档 | `%TEMP%\desens-backup2\`（共 19 个文件） | `.workbuddy/memory/*.md` 与 `archive/*.md` 脱敏前原文 |

两个备份**都含真实内网信息**。如果这套文档要对外分享，把 `.workbuddy/` 整个目录排除即可（它本来就是项目内部数据，不属于交付物）；
如果确认不再需要回滚，删掉上面两处备份，脱敏才算彻底。

恢复单个文件时从包里取，**不要整包解压覆盖**——那会把脱敏成果一起回退。
