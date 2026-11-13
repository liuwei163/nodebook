# MLOps 运维 / AI Infra 面试题库（结合自有项目经历版）

> 定位：**题库总纲**。推理优化深度叙事见《06-DeepSeek32B推理优化面试材料.md》（那张牌已经够硬，
> 本文不重复，只做索引和补充）。
> 每题格式：**问题 → 考点（面试官想听什么）→ 答题要点（结合你的项目）**。
> 原则：能挂到自己项目上的题，一定挂上去答——背概念的人一抓一大把，有数据的人没有。

---

## 0. 你手里已有的四张牌（素材映射表）

| 经历 | 支撑的问题域 | 出处材料 |
|---|---|---|
| ① DeepSeek-32B 推理优化（6.5 倍提速 + 架构对比） | 推理引擎、GPU、压测方法论、容量规划 | DeepSeek 面试材料 |
| ② MLflow 离线落地（部署→大模型登记→训练闭环→**落盘故障排查**→**自研监控**→备份运维体系） | MLOps 工具链、模型管理、离线环境、可观测性、运维 SOP（详见第九章实战沉淀） | 01-部署与模型登记/01-mlflow.yaml + 实操手册 ×3 + 监控手册 |
| ③ K8s 底座（NFS 静态 PV、Harbor、GitLab、Higress、ArgoCD） | 云原生基础、存储、网络、CI/CD | 01~04 主题目录/ |
| ④ 自研纯标准库压测工具 | 工程能力、离线环境应变 | DeepSeek 材料 2.2 节 |

**面试策略**：MLOps 岗位主打②③，①作为技术深度背书；AI Infra 岗位主打①④，②作为平台化视野背书。

---

## 1. 自我介绍与项目叙事

### 1.1 30 秒自我介绍（MLOps 运维版）

> 我是 Linux 运维出身，现在主要做 AI 平台侧。在离线 K8s 环境里我从 0 到 1 落地了模型资产管理平台
> （MLflow）：大模型登记、训练闭环、备份运维体系都是我建的；同时负责 DeepSeek-32B 推理服务，
> 通过定位 `--enforce-eager` 问题把生成速度提升 6.5 倍，并用对照实验推翻了原 PD 分离架构。
> 我的特点是：不只会部署，能用数据定位问题、验证结论。

### 1.2 30 秒自我介绍（AI Infra 版）

把上面第二句换重心：先讲推理优化（6.5 倍 + PD vs 共置的数据），再一句带过 MLflow 平台建设。

### 1.3 MLflow 项目 STAR（3 分钟叙事，MLOps 主打）

- **S**：公司模型文件散落在个人 NFS 目录，"现在生产用的是哪版模型"没人说得清；离线环境没有现成 SaaS 可用
- **T**：建一个离线可用的模型资产管理平台，把"训练→记录→注册→追溯"闭环立起来
- **A**：
  1. 离线导入 MLflow 2.17.2 镜像进 Harbor，K8s 部署：SQLite 元数据 + NFS artifacts，单副本 Recreate（保 SQLite 单写者）
  2. 踩了 4 个坑：参数版本差异（`--allowed-hosts`）、NFS v3 协议、挂载参数过多被拒、注册表 source 强制校验——对 65GB 已有大模型用"占位 run + `mlflow-artifacts:/` 前缀 + storage_path tag"方案绕开，并封装成脚本
  3. 建立运维体系：每日备份 CronJob（SQLite backup API 热备）+ 巡检脚本（磁盘水位/错误日志/备份新鲜度）+ 应急 SOP
  4. 打通训练闭环：Higress 暴露域名，本地/集群内客户端都能 log_model→register→load
- **R**：模型"哪个版本在 Production、来自哪次训练、权重在哪个路径"三个问题可以秒答；
  全流程有备份可恢复；这套东西后来直接支撑了 Jenkins 训练任务接入

### 1.4 简历要点（MLflow 项目）

- 离线 K8s 环境从 0 落地 MLflow 模型资产管理平台（SQLite+NFS 架构，单写者策略），支撑 65GB 级大模型登记与训练闭环
- 设计"占位 run + 代理协议 source"方案解决 MLflow 对存量模型登记不友好的问题，沉淀标准脚本
- 建立备份/巡检/应急 SOP：SQLite 在线热备、磁盘水位三级红线、升级回退预案（db 迁移只支持前滚的应对）

---

## 2. MLflow 深挖题（MLOps 岗位必考）

**Q1：MLflow 的存储架构？为什么要分两个存储？**
考点：是否真理解而非只会 UI。
要点：元数据（实验/run/参数/指标/注册表记录）进数据库 `--backend-store-uri`；产物（模型文件/图表）进 artifact store `--default-artifact-root`。类比借阅卡与书架——检索走库、实体走文件，两者独立扩容和备份。

**Q2：代理模式和 file 模式区别？你们为什么选代理？**
考点：多客户端架构理解（你踩过的最大的认知坑）。
要点：客户端走 HTTP 时 artifact_uri 永远是 `mlflow-artifacts:/`，文件经 server 中转落 NFS；file 模式要求每个客户端直挂存储。选代理因为：客户端零挂载零凭据、权限集中、跨机器可用；代价是 server 变成带宽瓶颈、大文件过网关（413 风险）。我们的训练 Pod 不挂任何盘就能写模型，就是代理模式的直接收益。

**Q3：为什么敢用 SQLite？什么时候必须换 PostgreSQL？**
考点：容量规划与边界意识。
要点：SQLite 单写者——所以我们 replicas 恒为 1 + `strategy: Recreate`，从机制上保证不会双写损坏；日志出现 `database is locked` 或第二团队并发写入，就是迁移 PostgreSQL 的触发条件。能说清"当前方案成立的前提"比直接说"上 PostgreSQL"高级。

**Q4：65GB 已有大模型怎么登记进 MLflow？（你的招牌题）**
考点：源码级理解 + 务实取舍。
要点：MLflow 注册表强制 source 必须来自某个 run 的 artifact 目录（2.17 实测，纯路径/file:/// 全被拒）。方案：REST 建占位 run → 在 run 的 artifact 目录建占位子目录 → source 填 `mlflow-artifacts:/0/<run_id>/artifacts/<模型名>` → 真实 NFS 路径记 storage_path tag。要点出取舍：登记≠拷贝，MLflow 只记指针；这是"逆着设计走"，等训练流程建立后应回归 log_model 闭环。

**Q5：Model Registry 机制？怎么衔接发布？**
要点：Registered Model → Version → Stage（None/Staging/Production/Archived）；source 指向 run artifact；训练完 `register_model` 自动进注册表，切 Stage 就是发布动作；新旧版本切 Production 可自动归档旧版。

**Q6：MLflow 怎么备份？SQLite 在线备份原理？**
要点：`sqlite3` backup API（`src.backup(dst)`）可在服务不停时拿到一致性副本；备到同 NFS 并保留 30 天（CronJob）；三层验证——文件存在、`PRAGMA integrity_check`、季度恢复演练。**必说盲区**：备份与原件同盘，防库损坏不防盘丢，所以每周拷出 NFS 一份/依赖存储快照。

**Q7：元数据和产物备份策略为什么不lev相同？**
要点：db 小（MB 级）价值密度高 → 高频备份+异地拷贝；artifacts 大且多数可再生 → 存储侧快照即可；大模型权重在别的 NFS → 按共享维度由存储组保障，MLflow 侧保"路径+版本台账"可重建。

**Q8：MLflow vs W&B vs DVC？为什么选 MLflow？**
要点：离线内网首要素——可完全自托管、镜像单文件即可离线导入；功能覆盖 tracking+registry+projects；W&B SaaS 依赖外网（否决）、DVC 偏数据版本不覆盖注册表。选型看环境约束，不看社区热度。

**Q9：客户端和服务端版本不一致会怎样？你们怎么管？**
要点：protobuf/接口漂移会报错；措施——练习/训练镜像里 pip 版本锁死 2.17.2，升级时 initContainer 跑 `mlflow db upgrade` + 通知所有客户端同步升级。

**Q10：MLflow 没有认证，你怎么管安全？**
要点：承认事实；保持 ClusterIP；外部暴露走 Higress + basic-auth 插件（客户端 MLFLOW_TRACKING_USERNAME/PASSWORD）；kubectl exec 权限按管理员管理；约定删除双人确认 + 备份兜底。

---

## 3. MLOps 通用概念题

**Q：MLOps 和 DevOps 的区别？**
考点：是否理解"模型"这个新资产。
要点：三个增量——①版本对象多了数据+模型（不只是代码）②模型会因数据漂移退化，需要 CT（持续训练）③上线前要模型验证（不只是单元测试）。CI/CD 扩展成 CI/CD/CT。

**Q：MLOps 成熟度分级？你们在哪级？**
要点：Google 分级 L0 手工（Notebook 跑脚本）/ L1 训练 pipeline 自动化 / L2 CI/CD+CT 全自动。答法："我们在 L0.5 → L1 过渡：训练记录和注册已平台化（MLflow），训练任务已进 Jenkins，下一步是数据验证和自动触发再训练"——给出当前位置+下一步，比背定义强。

**Q：模型上线后监控什么？**
要点：三类——服务指标（QPS/延迟/错误率，运维熟）、数据漂移（特征分布 KS/PSI）、模型效果（线上延迟收集标签算 AUC/准确率；LLM 场景用 eval 集定期回归）。可补一句：我们 MLflow 记录训练指标作为基线，线上对照。

**Q：LLMOps 和传统 MLOps 的差异？**
要点：prompt 当版本管理对象、eval 取代传统指标评测、GPU 成本约束、推理参数（TPOT/TTFT）纳入 SLO——自然接到你 DeepSeek 压测的 Goodput 观点（SLA 内最大吞吐才是容量）。

**Q：数据/特征版本管理怎么做？**（概念题，别装深）
要点：DVC（数据文件哈希+git 指针）、特征仓库（Feast：离线/在线特征一致性）；诚实说"我们目前数据还在共享盘，这是我下一步要补的"——承认边界比编造安全。

---

## 4. AI Infra / 推理题（深度叙事用已有文档，这里补基础盘）

**指标四件套（必背，附你的实测数字）**
- TTFT 首字延迟（你实测 340→173ms）；TPOT 每字间隔（146.5→22.6ms，判断用户体验的指标）；吞吐 tok/s（判断成本）；Goodput（满足 SLA 的有效吞吐，128 并发 2759 tok/s 那组数据）
- 金句：**判断体验看 TPOT，判断成本看总吞吐，报价容量看 Goodput**

**Q：PagedAttention 解决什么问题？**
要点：传统方式按请求预留连续 KV 显存 → 内外部碎片、碎片率可达 60-80%；PagedAttention 把 KV 切成固定 block 按页表管理、按需分配、可共享（prefix cache），显存利用率大幅提升 → 同卡可支撑并发数倍增。

**Q：continuous batching 和 static batching 区别？**
要点：static 等一批齐进齐出，短请求被长请求拖死；continuous 每个迭代步动态插入/退出请求，GPU 一直有活干。这就是 vLLM 吞吐高的核心之一。

**Q：KV cache 大小怎么估算？（现场算数题）**
公式：`2(K+V) × 层数 × KV头数 × head_dim × dtype字节数 × seq_len`。
示例 DeepSeek-32B：2×64层×8头×128维×2字节(BF16) = 256KB/token——和你实测文档里的数字正好闭环。追问"多机 TP 时怎么分"：每层 KV 按头切分到各卡。

**Q：为什么 decode 是 memory-bound、prefill 是 compute-bound？**
要点：decode 每步只算 1 个 token，却要把全部权重读一遍 → 卡在 HBM 带宽（你算过：16.3GB/1.6TB/s≈10ms，这正是判定 146ms 异常的依据）；prefill 整段并行算 → 卡在算力。推论：decode 优化靠提高带宽利用率（图模式/融合）、prefill 优化靠算力与调度（chunked prefill）。

**Q：量化怎么选？**
要点：W8A8（权重激活都 INT8，昇腾 msmodelslim 路径）/ 权重-only（AWQ/GPTQ，INT4 压显存）/ FP8（H 卡一代）；收益=显存减半→KV 更多→并发更高，风险=精度损失必须 eval 验证。说出"先验证精度再上"就是加分项。

**Q：GPU 利用率 100% 说明高效吗？**
要点：不。nvidia-smi 只反映"有 kernel 在跑"；真实效率看 MFU（实测算力/理论峰值）。memory-bound 的 decode 甚至可以"占用 100% 但慢"。引导到你的压测方法论。

**Q：GPU 在 K8s 里怎么调度？**
要点：device-plugin 上报扩展资源（`nvidia.com/gpu` / 昇腾 `huawei.com/Ascend910`）、Pod 声明整卡；Volcano 提供 gang scheduling（分布式训练全员到齐才起）、队列配额、拓扑感知；共享方案 MIG（物理隔离）/ vGPU / time-slicing（弱隔离）。你的 TP8 部署 = 8 卡整卡调度实例。

**Q：多机训练/推理的网络要求？**
要点：NCCL 集合通信；跨机走 RDMA（IB 或 RoCE）绕过内核协议栈降延迟；参数面/存储面/通信面网络分离；两千卡级还涉及轨道优化组网。诚实划界："我实操到单机 8 卡 TP，多机组网了解原理"。

**Q：推理服务显存都花在哪？**
要点：权重（32B BF16≈65GB）+ KV cache（随并发线性涨）+ 激活/框架开销；`--gpu-memory-utilization` 就是在分配"权重之外的可用池"。呼应你日志里"Available KV cache 39.92 GiB/卡"。

---

## 5. K8s 与云原生（主业底盘，快速过）

- **PV/PVC/StorageClass**：无动态供应时手动 PV+`volumeName` 显式绑定（你的 NFS 实操）；Retain 策略防误删
- **NFS 坑（你的招牌实战）**：服务端只支持 v3 就写 `vers=3`；挂载参数宁少勿多（加一堆 rsize/wsize 反而 access denied）；照抄同集群已验证组件；**SQLite 不该放 NFS**（文件锁不可靠）但单写者+Recreate 下风险可控——完整展现"知道规则也知道何时可以偏离规则"
- **Recreate vs RollingUpdate**：单写者场景选 Recreate（绝不允许新旧 Pod 同时写库）——把部署策略和存储特性关联起来答
- **三种探针**：liveness（挂了重启）/ readiness（没好不接流量）/ startup；你们 mlflow 用 /health
- **requests/limits 与 QoS**：Guaranteed/Burstable/BestEffort 与节点压力驱逐顺序
- **HPA**：CPU/内存默认指标；推理服务用自定义指标（并发数/队列长度）才有意义
- **CrashLoopBackOff 排查五连**：logs --previous → describe events → args/版本兼容 → 探针配置 → 资源 OOMKilled（你的 `--allowed-hosts` 案例直接用）
- **Higress/Ingress**：Host+路径路由、后端 service、注解控制超时/长度；你把 mlflow 暴露出去的完整链路就是答题素材
- **imagePullSecrets**：namespace 级隔离，跨 ns 要复制（你复制 harbor-secret 的实操）

---

## 6. Linux/网络基础速览（一题一句版）

- 三次握手为什么不是两次：防历史重复连接请求造成资源错配
- TIME_WAIT 过多：短连接高频，调 `tw_reuse`/长连接化
- `df` 和 `du` 不一致：文件已删除但进程仍持有句柄——磁盘满应急先 `lsof | grep deleted`（运维加分细节）
- 进程/线程/协程：切换成本与调度者不同；vLLM 的 frontend worker 就是多进程/协程混合
- IO 五种模型一句话：blocking/non-blocking/IO multiplexing(select-epoll)/signal/async；epoll 红黑树+就绪链表
- NFS 锁：NLM 协议，v3 锁不可靠 → 这就是"SQLite 别放 NFS"的根源（你的知识闭环）
- 排查磁盘满四板斧：df → du 定位 → lsof deleted → 清理/journalctl 日志瘦身

---

## 7. 场景设计题（给框架，不背答案）

**Q：设计一个多团队共用的模型资产管理平台（离线环境）**
框架 = 你的真实方案：元数据库（可演进 PostgreSQL）+ 对象存储/共享文件系统 + 统一注册表（版本/Stage/tag）+ 网关认证 + 备份体系 + 登记脚本兼容"存量模型" + 训练侧 SDK 约定（log_model→register）。收尾补演进触发条件（并发写→PG、容量→S3、开放→认证）。

**Q：给一个新的大模型推理服务设计上线方案**
框架：压测定容量（区分突发/稳态流量，Goodput 定水位）→ 资源与调度（整卡/Volcano 队列）→ 灰度（先 5% 流量看 TPOT/TTFT p99）→ 监控（业务指标+GPU 指标+日志关键字）→ 回滚预案（镜像+配置版本化）。每步都能引你 DeepSeek 实测数据。

**Q：离线环境怎么建设 AI 工具链？**
框架：镜像导入流水线（外网构建→save/load→Harbor）+ 内网 pip 源 + 版本锁定纪律 + "照抄集群已验证配置"原则 + 文档沉淀（你每份手册都是证据）。

**Q：训练任务怎么和模型平台打通（CI 场景）？**
框架：Jenkins Job 内 `MLFLOW_TRACKING_URI` 指向平台 → 训练脚本 log 参数指标 → register_model 自动注册 → 打 Staging → 人工/自动评审切 Production → 注册表即台账。客户端版本锁定与平台同步升级。

---

## 8. 收尾准备

**反问清单（挑 2-3 个）**
- 团队 GPU 规模和卡型？训练/推理配比？
- 平台现状：模型管理、训练提交、推理服务各自什么水平？最痛的点是什么？
- 这个岗位前 3 个月最重要的交付是什么？

**3 天冲刺计划**
1. D1：把《DeepSeek-32B-推理优化-面试材料》过到能脱稿复述（含方法论 8 条和追问 6 题）
2. D2：把本文 MLflow 十题 + 场景题框架过两遍，30 秒/3 分钟自我介绍对着镜子练 3 次
3. D3：准备三个故障故事（enforce-eager 6.5 倍 / NFS 挂载参数坑 / SQLite 部署取舍），每故事 90 秒——面试官问"讲个你解决过的难题"时直接调用

**三个故障故事模板（STAR 压缩版）**
1. **6.5 倍提速**：TPOT 146ms 异常 → 理论反推（10ms 应为）→ 定位 enforce-eager → 单变量修复 → 数据闭环
2. **NFS 挂载三连坑**：Protocol not supported → 查 mount 得 vers=3 → 参数过多被拒 → 照抄已验证配置 → 沉淀"抄集群不抄博客"原则
3. **大模型登记无门**：source 校验全拒 → 读报错定位强制校验逻辑 → 占位 run+代理前缀+tag 记真实路径 → 封装脚本 → 主动指出长期方案

---

## 九、MLflow 实战沉淀（2026-11-04 ~ 11-06，操作学习总结）

> 这是从零上手 MLflow 三天的全部沉淀：不只"会用"，而是踩过坑、修过故障、建过监控。
> 面试中所有 MLflow 相关问题，优先挂这段真实经历。

### 9.1 学习历程时间线（自我叙述的素材骨架）

| 阶段 | 做了什么 | 沉淀的知识点 |
|---|---|---|
| 部署认知 | SQLite+NFS、单副本 Recreate、代理模式 | 双存储架构；单写者策略的机制化（不是口头约定） |
| 大模型登记 | 占位 run + `mlflow-artifacts:/` 前缀 + storage_path tag | 注册表强制"模型必须来自 run artifact"的设计约束 |
| 客户端接入 | 集群内 svc / port-forward / Higress 域名 | 三种网络路径的取舍（内网走 svc 少一跳） |
| 本地训练环境 | py 3.11 统一版本、pip 代理四层排错 | Windows 多版本 Python 错位；注册表系统代理 |
| 真模型闭环 | 训练→注册→champion→load 验证 | 6 个核心 API；artifact 目录懒创建 |
| 发布语义 | Stage deprecated → Aliases | champion/canary/challenger/shadow 角色约定 |
| **落盘故障** | NFS 看不到产物 → 定位容器本地 `/mlartifacts` | serve-artifacts 默认开启；artifacts-destination |
| 监控建设 | 自研纯标准库 sidecar exporter | 无原生 metrics 平台的监控套路 |

### 9.2 新增面试题（结合实战，答法优先挂真事）

**Q11（招牌故障案例）：你们 MLflow 在 NFS 上看不到新训练的产物，怎么排查和修复的？**
考点：默认值意识 / 系统化排查 / 数据安全操作顺序
要点：①现象反直觉——UI 一切正常、训练显示成功，节点 NFS 只有旧占位目录；②假设——产物根本没写 NFS；③验证——exec 进容器 `find` 定位 `/mlartifacts` 在容器根目录，查 experiments 表 artifact_location 全是 `mlflow-artifacts:/`；④根因——2.x 的 `mlflow server` **默认开启** `--serve-artifacts`，代理模式下 `--default-artifact-root` **被忽略**，写入位置由 `--artifacts-destination` 决定（默认 `./mlartifacts` = 容器本地）；⑤修复顺序——**先 cp 迁移数据、再改配置**（Recreate 策略重启即丢盘）；⑥验证——重启后 load 仍通 + 新训练落 NFS。元数据不受影响（db 显式绝对路径）。

**Q12：MLflow 没有原生 Prometheus 指标，你们怎么做监控？**
考点：无原生可观测性平台的通用解法
要点：自研 sidecar exporter（**纯标准库**，零新镜像，离线可用）——/health 探活、statvfs 量 /data 磁盘、sqlite **只读模式**查实验/run/模型版本计数，15s 一轮；Pod 注解（prometheus.io/scrape）让 kube-prometheus-stack 自动抓取；Grafana 6 面板看板；三条告警（ServerDown / DiskHigh / MetricsMissing）。对比黑盒探针：只能覆盖可用性，业务计数必须自研导出器。

**Q13：MLflow 的 Stage 为什么被弃用？Aliases 好在哪？**
考点：发布机制的演进理解（有第一手 UI 体验）
要点：Stage 全局唯一（一个模型只能有一个 Production），表达不了灰度；Aliases 是**多指针并存**——champion（主力）/ canary（灰度 10%）/ challenger（候选打擂）/ shadow（影子对比不回包）可同时存在；发布=把 champion 挪到新版本，回滚=挪回来，全程不改代码不重启；调用方引用 `models:/name@champion` 与版本号解耦。

**Q14：load_model 会把文件下载到哪？留在本地吗？**
考点：取回机制细节
要点：下载到系统临时目录（Windows 为 AppData\Local\Temp\tmpXXX），模型对象还原进内存后**立即自动删除**；无本地缓存，每次 load 重新拉；要永久保存用 `mlflow.artifacts.download_artifacts(uri, dst_path=...)`；三种用模型方式对比（load=临时 / download=永久 / serve=服务化）。

**Q15：sidecar 只读查 sqlite，不会破坏服务端单写者吗？**
考点：SQLite 并发模型准确表述
要点：SQLite 限制的是**多写者**，并发只读是安全的；连接显式用 `file:...?mode=ro` 只读 URI 声明意图；写者仍唯一（服务端进程）。备份的 backup API、导出器的计数查询、巡检脚本，全是"读"——**读不破坏单写者，多写才破坏**。

**Q16：离线 Windows 上 pip 装包报 "Could not find a version"，怎么排？**
考点：网络代理层次排查
要点：四层递进——①python/pip 版本错位（`py -3.11` 统一解释器）；②清环境变量代理后发现还不行；③**pip 会读 Windows 注册表系统代理**（getproxies 兜底），必须 `--proxy` 显式覆盖；④真直连测试发现超时（无外网）→ 换可用公司代理解决。经验：区分报错语义——`from versions: none`（拿到响应但被过滤/拦截）vs ProxyError 502 vs timeout，对应不同层。

**Q17：你们模型从训练到生产的完整流程是什么？**
考点：端到端流程叙述能力
要点：训练（记 params/metrics 曲线/图/模型）→ 自动注册新版本 → 挂 challenger 跑评测 → canary 灰度 → champion 切换（发布）→ 调用方按 `@champion` 取回 → 65GB 存量大模型走登记脚本（指针+storage_path tag）。运维保障三件套贯穿：备份 CronJob、水位告警、每日巡检。

### 9.3 简历要点更新（MLflow 项目叙事 v2）

- 离线 K8s 从 0 落地 MLflow 模型管理平台（SQLite+NFS、单写者策略、Higress 暴露），打通"训练→注册→发布→取回"完整闭环
- **独立定位并修复产物落盘故障**：确认 2.x serve-artifacts 默认行为与 artifacts-destination 的关系，按"先迁移再变更"原则完成修复，避免 Pod 重启导致数据丢失
- 自研**零依赖 Prometheus 导出器**（sidecar 模式，纯标准库），补齐 MLflow 服务健康/磁盘水位/业务规模监控与三条告警规则
- 建立运维 SOP：SQLite 在线热备 + CronJob、三级磁盘水位红线、"前滚式升级"的回退预案

### 9.4 金句库（过渡和收尾用）

1. **"没配 = 默认值也是配置"**——任何组件排错/升级前，先确认它的默认行为
2. **"UI 正常 ≠ 文件在想的盘上"**——代理模式下，验证必须落到最终存储
3. **"发布 = 挪指针，回滚 = 挪回来"**——Aliases 的发布语义
4. **"读不破坏单写者，多写才破坏"**——SQLite 并发的准确表述
5. **"训练在哪儿跑无所谓，台账只有一个"**——客户端与服务端解耦

### 9.5 新增故障故事（第 4 个，90 秒版）

**产物落盘故障**：本地训练成功、UI 全正常，但节点 NFS 上看不到产物 → 提出假设"没写到 NFS"→ exec 进容器 find 到 `/mlartifacts` 在容器根目录 → 对照官方 CLI 文档确认 2.x serve-artifacts 默认开启、default-artifact-root 被忽略 → 按"先迁移再变更"迁移数据、替换参数 → 重启后闭环验证 → 勘误沉淀进部署文档。面试官听到的不是"我改了个配置"，而是**一套完整的假设-验证-修复-沉淀流程**。
