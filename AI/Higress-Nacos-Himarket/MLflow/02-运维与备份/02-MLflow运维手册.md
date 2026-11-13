# MLflow 运维手册（职责拆解版）

> 环境：MLflow 2.17.2 · ml-platform 命名空间 · SQLite + NFS 50Gi · 单副本 Recreate · 离线集群
> 配套物料：`02-运维与备份/02-mlflow-daily-check.sh`（巡检）· `02-运维与备份/02-mlflow-backup.sh`（手动备份）·
> `02-运维与备份/02-mlflow-backup-cronjob.yaml`（自动备份）
> 读者：运维工程师。不需要懂算法。

---

## 0. 运维对象盘点：你到底在维护什么

| 组件 | 位置 | 里面是什么 | 挂了/丢了会怎样 |
|---|---|---|---|
| Deployment `mlflow` | ml-platform，1 副本，Recreate | Web UI + API 进程 | 重启即恢复，**无状态，不怕** |
| SQLite 数据库 | Pod 内 `/data/mlflow.db` | **全部实验记录、参数、指标、模型注册表** | 丢 = 台账清零，最严重的事故 |
| Artifact 目录 | Pod 内 `/data/artifacts/` | 上传的模型文件、图表、报告 | 丢 = 文件无法下载/加载（记录还在） |
| PV `mlflow-data-pv` | NFS 50Gi，Retain | 上面两样**同住一块盘** | NFS 故障 = 两样一起丢 |
| Service `mlflow` | ClusterIP:5000 | 集群内访问入口 | 秒级重建，不怕 |
| `harbor-secret` | ml-platform | 拉镜像凭据 | Pod 起不来 |

**三条关键认知**：

1. 服务本身无状态 → Pod 级故障重启就好，**运维重心 90% 在数据上**
2. 元数据（db）和文件（artifacts）在**同一块 50Gi NFS** 上 → 磁盘是第一风险，备份是第二
3. 大模型权重**不在**这块盘里（在别的 NFS 路径，靠注册表 tag 记路径）→ 那部分归"模型台账"管理，不归这块盘管

---

## 1. 职责总览：运维 MLflow = 五件事

| # | 职责 | 频率 | 耗时 | 不做的后果 |
|---|---|---|---|---|
| 1 | 巡检 | 每班/每天 | 5 分钟（有脚本） | 故障发现滞后，小问题拖成大问题 |
| 2 | 备份与恢复演练 | 每天（自动）+ 每季度演练 | 部署一次后免维护 | db 损坏 = 全部台账永久丢失 |
| 3 | 清理与数据治理 | 每周~每月 | 10 分钟 | 磁盘涨满，服务写入报错 |
| 4 | 容量管理 | 每月看一眼 + 告警兜底 | 5 分钟 | artifacts 悄悄吃满 50Gi |
| 5 | 升级与变更 | 每季度评估 | 半小时 | 版本老化，但**不升也不塌** |

下面逐项拆解。

---

## 2. 巡检（每天 5 分钟）

### 2.1 一键巡检

```bash
bash 02-运维与备份/02-mlflow-daily-check.sh
```

输出逐项 `[通过]/[预警]/[异常]`，退出码 0/1 可直接接告警系统。

### 2.2 检查项与判断标准

| 检查项 | 命令（手动版） | 正常标准 | 异常时先看 |
|---|---|---|---|
| Pod 状态 | `kubectl -n ml-platform get pods -l app=mlflow` | Running，1/1，重启 <3 | `kubectl logs --previous` |
| 健康 | `kubectl exec deploy/mlflow -- python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:5000/health').status)"` | 200 | describe 看 probe 失败原因 |
| 磁盘 | `kubectl exec deploy/mlflow -- df -h /data` | <70% | 见第 5 节容量管理 |
| 错误日志 | `kubectl logs deploy/mlflow --tail=300 \| grep -iE "error\|locked"` | 无 | `database is locked` 见第 8 节 |
| 备份新鲜度 | `kubectl exec deploy/mlflow -- ls -t /data/backup \| head -1` | 最新备份 <48h | CronJob 是否被删/失败 |
| UI 可用 | 浏览器打开 | 能加载实验列表 | Service/Endpoints |

### 2.3 巡检的"要命项"只有两个

- **备份新鲜度**：备份链断了比服务挂了严重得多——服务挂影响今天，备份断影响永远
- **磁盘水位**：SQLite 写满盘会直接报错拒写，且可能留下损坏文件

---

## 3. 备份与恢复（最重要的一件事）

### 3.1 备什么

| 对象 | 方式 | 说明 |
|---|---|---|
| `/data/mlflow.db` | SQLite backup API 热备 | 台账本体，**必须备份** |
| `/data/artifacts/` | NFS 快照/存储侧备份（找存储组确认） | 文件多但可再生成价值有限；重点保 db |
| 部署清单 | 已在 git（`01-部署与模型登记/01-mlflow.yaml`） | 重建集群时用 |

### 3.2 怎么备（自动化）

```bash
# 一次性部署自动备份（每天跑，保留 30 天）
kubectl apply -f 02-运维与备份/02-mlflow-backup-cronjob.yaml

# 验证：手动触发一次并看日志
kubectl -n ml-platform create job --from=cronjob/mlflow-backup mlflow-backup-manual
kubectl -n ml-platform logs job/mlflow-backup-manual        # 看到 backup-ok: 日期 即成功
```

手动补一次：`bash 02-运维与备份/02-mlflow-backup.sh`

### 3.3 备份有效性三层验证（多数人只做到第 1 层）

1. **文件层**：`ls -lh /data/backup/` 有新文件，大小与主库同量级
2. **完整性层**（备份脚本已内置）：`PRAGMA integrity_check` 返回 ok
3. **恢复层**（每季度一次）：按 3.5 真的恢复一次到验证可用——**没演练过的备份等于没备份**

### 3.4 备份的盲区（必须写进风险台账）

- 备份和原件在**同一块 NFS** 上：能防"库损坏/误删"，防不了"NFS 整体丢失"
  → 对策：每周把最新备份拷出 NFS 一次：
  `kubectl -n ml-platform cp deploy/mlflow:/data/backup/<最新文件>.db ./mlflow-backup/`
  或与存储组确认 NFS 共享有快照策略
- 注册表里大模型的**权重本体在别的 NFS 路径**：db 备份保住的是"路径+版本台账"，
  权重文件的备份要找存储组按 NFS 共享维度确认

### 3.5 恢复 SOP（db 损坏/误操作后）

```bash
# ① 停止写入（Recreate 策略下自然单写者）
kubectl -n ml-platform scale deploy/mlflow --replicas=0

# ② 起一个临时 helper Pod 挂同一块 PVC 做文件操作
kubectl -n ml-platform apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: mlflow-restore, namespace: ml-platform}
spec:
  restartPolicy: Never
  imagePullSecrets: [{name: harbor-secret}]
  containers:
  - {name: helper, image: "harbor.ai.cnpc/ai-platform-poc/mlflow:v2.17.2",
     command: ["sleep", "3600"], volumeMounts: [{name: data, mountPath: /data}]}
  volumes:
  - {name: data, persistentVolumeClaim: {claimName: mlflow-data}}
EOF

# ③ 保留现场 + 用备份顶上（把坏库改名留着排查，别直接删）
kubectl -n ml-platform exec mlflow-restore -- \
  sh -c "cp /data/mlflow.db /data/mlflow.db.bad-$(date +%F) && \
         cp /data/backup/mlflow-<最新备份>.db /data/mlflow.db"

# ④ 清理 helper，恢复服务
kubectl -n ml-platform delete pod mlflow-restore
kubectl -n ml-platform scale deploy/mlflow --replicas=1

# ⑤ 验证：UI 打开、实验列表在、随机点开一个 run 参数指标正常
```

误删 run/模型版本（库没坏，只是删错了）：同法用旧备份起**临时实例**（换端口跑一个
`mlflow server --backend-store-uri sqlite:////data/backup/xxx.db`），把要的数据导回主库。

---

## 4. 清理与数据治理（防膨胀）

### 4.1 删除的两层机制（很多人不知道第二层）

| 层 | 动作 | 效果 |
|---|---|---|
| 软删除 | UI 删 run / 删实验 | 只是打 `deleted` 标记，界面看不见，**文件还在** |
| 硬删除 | `mlflow gc` | 真正回收 artifact 文件 |

```bash
# 例行清理（先 UI 里删，再回收）：
kubectl -n ml-platform exec deploy/mlflow -- \
  mlflow gc --backend-store-uri sqlite:////data/mlflow.db
```

### 4.2 SQLite 文件只涨不缩 → VACUUM

删数据不会让 db 文件变小，磁盘紧张时（需要先 `--replicas=0` 停写）：

```bash
kubectl -n ml-platform scale deploy/mlflow --replicas=0
kubectl -n ml-platform exec deploy/mlflow -- python -c \
  "import sqlite3; c=sqlite3.connect('/data/mlflow.db'); c.isolation_level=None; c.execute('VACUUM'); c.close()"
kubectl -n ml-platform scale deploy/mlflow --replicas=1
```

### 4.3 给团队立的规矩（治理靠约定，不靠事后清理）

- 实验命名：`项目-模型-日期`（如 `deepseek-r1-eval-20261104`）
- 每条 run 必须写 Description 和 owner tag
- 练习/废弃数据当周删除；Production 模型版本只许加不许删

---

## 5. 容量管理（红线与扩容）

### 5.1 50Gi 的构成与吃盘速度

| 内容 | 增长速度 | 说明 |
|---|---|---|
| mlflow.db | 慢（KB~MB 级/月） | 参数指标都是小文本 |
| artifacts/实验附件 | 中 | 图表、小模型文件 |
| **有人 log_model 大模型** | **一次就爆** | 65GB 权重 >> 50Gi 盘，**铁律：大模型只走 01-register-model.sh 台账** |

### 5.2 三条水位线与对应动作

| 水位 | 动作 |
|---|---|
| 70% | 预警：巡检脚本已会提示；安排一次清理（删废弃 run → gc → 必要时 VACUUM） |
| 85% | 处置：立即清理；同时找存储组评估 NFS 扩容 |
| 90% | 紧急：直接联系存储组扩容，同时冻结大文件上传 |

### 5.3 扩容路径（静态 PV 不支持原地扩容）

1. 存储组把 NFS 共享扩容（或新开更大共享）
2. 新建大容量 PV + 新 PVC → 起临时 helper Pod `cp -a` 迁移数据 → Deployment 换绑新 PVC
3. 旧 PV 因 `Retain` 数据仍在，确认无误后再清理

长期看，磁盘压力持续增长就是迁 PostgreSQL + MinIO/S3 的信号（见第 11 节）。

---

## 6. 升级与变更管理

### 6.1 什么时候升级

版本没有安全漏洞、没有阻塞性 bug 时**可以不升**——台账服务的价值在数据连续性。
升级的两个真实动机：官方修复了你踩到的 bug、需要新版本才支持的功能（如 2.18+ 的 `--allowed-hosts`）。

### 6.2 升级 SOP（8 步）

```bash
# ① 确认备份新鲜（<24h），手动再备一次最稳
bash 02-运维与备份/02-mlflow-backup.sh

# ② 新版本镜像按老流程导入 Harbor（如 mlflow:v2.18.x）
# ③ 通知所有使用方（算法/Jenkins）准备好同步升级客户端 pip 版本
# ④ 改 01-部署与模型登记/01-mlflow.yaml：镜像 tag 改新版本，并加 initContainer 做库结构迁移：
#      initContainers:
#      - name: db-migrate
#        image: harbor.ai.cnpc/ai-platform-poc/mlflow:v2.18.x
#        command: ["mlflow","db","upgrade","sqlite:////data/mlflow.db"]
#        volumeMounts: [{name: data, mountPath: /data}]
# ⑤ kubectl apply（Recreate 策略：先停旧再起新，迁移时天然无第二个写者）
# ⑥ 验证：巡检脚本全绿 + UI 开旧实验看数据完好 + 跑一次小训练
# ⑦ 通知使用方统一升级 pip 客户端到同版本
# ⑦ 观察 3 天，无异常后把备份保留期内的旧镜像 tag 留着
```

### 6.3 回退预案（升级失败的底牌）

**MLflow 的库结构迁移只支持向前，不支持降级。** 回退 = 两步：
旧版本镜像 tag 改回 + 用升级前的 db 备份恢复（按 3.5 节 SOP）。这就是升级前必须备份的原因。

---

## 7. 安全与访问控制

| 事项 | 现状与做法 |
|---|---|
| 认证 | MLflow 开源版**无任何认证**：能打开 UI = 能删一切。这是最大安全事实 |
| 网络边界 | Service 保持 ClusterIP 不暴露公网；给新人开 UI 访问 = 给他删库权，按需开 |
| 上 Ingress 前置条件 | 必须套 Nginx Basic Auth + TLS，否则不上 |
| 网关暴露（Higress） | 用 Higress 域名转发 5000 时：① 路由需**全路径转发**（artifact 上传走 `/api/2.0/mlflow-artifacts/...`）；② 建议开 basic-auth 插件（客户端配 `MLFLOW_TRACKING_USERNAME/PASSWORD` 即可通过）；③ 大文件上传报 413/超时时，调网关请求体上限与超时；④ HTTPS 自签证书会让客户端报 SSL 错，正式做法装企业 CA，应急可设 `MLFLOW_TRACKING_INSECURE_TLS=true` |
| NetworkPolicy（可选） | 需 CNI 支持（Calico/Cilium）；只放行 ml-platform 本ns + Jenkins 命名空间访问 5000 端口 |
| kubectl exec | 等于直接摸生产数据文件，权限按运维管理员管理 |
| 审计 | MLflow 无操作日志，追责靠 K8s auditlog（若有）+ 团队约定 |

---

## 8. 故障应急 SOP（按现象查）

| 现象 | 判断 | 处置 |
|---|---|---|
| **CrashLoopBackOff** | `kubectl logs --previous` 看死因 | 常见：args 参数与版本不匹配（如 `--allowed-hosts` 是 2.18+ 的）、PVC 挂载失败、OOM。改 yaml 修正后 apply |
| **database is locked** | 日志出现此关键字 | ① 确认副本数=1、无第二个进程直连 NFS 上的 db（有人用 file:// 模式绕过 server 写库是典型原因）② 偶发可忽略；反复出现 = 启动 PostgreSQL 迁移 |
| **磁盘满（写入 500/报错）** | df 显示 100% | 冻结上传 → 删废弃 run → `mlflow gc` → VACUUM → 联系存储扩容 |
| **UI 打不开但 Pod 正常** | `kubectl get endpoints mlflow` | Endpoints 空 = Service selector 问题；有 IP 则查网络策略/浏览器侧 |
| **客户端连不上** | 客户端报 Connection refused | 查客户端 tracking_uri、跨 ns 的 DNS（用全域名 `mlflow.ml-platform.svc.cluster.local`）、NetworkPolicy |
| **误删实验/模型版本** | 有人说"数据没了" | **先停手别再操作**，按 3.5 用旧备份起临时实例找回；平时约束：删除操作双人确认 |
| **NFS 异常/共享漂移** | Pod 起不来，挂载报错 | 联系存储组；若共享路径变了，改 PV 的 `nfs.path` 后重启（数据在 NFS 上没丢） |

---

## 9. 周期任务总表（可直接贴在交接文档里）

| 周期 | 动作 | 工具 |
|---|---|---|
| 每天 | 跑巡检脚本；看备份新鲜度 | `02-运维与备份/02-mlflow-daily-check.sh` + 备份 CronJob 自动 |
| 每周 | 最新备份拷出 NFS 一份；浏览 UI 检查新实验命名规范 | `kubectl cp` |
| 每月 | 磁盘水位复盘（趋势）；清理废弃 run + gc | 巡检输出 + 第 4 节 |
| 每季度 | **恢复演练一次**（3.5 节全流程）；评估是否升级 | 3.5 + 6.2 |
| 按需 | 扩容、迁移 PostgreSQL、加认证 | 第 5/11 节触发条件 |

---

## 10. 资产卡（交接时填这份）

| 项 | 值 |
|---|---|
| 镜像/版本 | `harbor.ai.cnpc/ai-platform-poc/mlflow:v2.17.2` |
| 命名空间 / Service | `ml-platform` / `mlflow:5000` (ClusterIP) |
| 数据位置 | NFS `v4nassg02.v4hhht03.az1:/mnt/Volume_03/manila/share_a30f.../mlflow`（db + artifacts 同盘 50Gi） |
| 备份 | CronJob `mlflow-backup`，每日，NFS `/data/backup/`，保留 30 天；**另需每周拷出 NFS** |
| 已知风险 | SQLite 单写者（locked 风险）；无认证；备份与原件同盘 |
| 部署清单 | `01-部署与模型登记/01-mlflow.yaml` · 备份 `02-运维与备份/02-mlflow-backup-cronjob.yaml` |
| 模型登记脚本 | `01-部署与模型登记/01-register-model.sh`（大模型台账模式） |
| 相关文档 | `01-部署与模型登记/01-MLflow离线部署与模型登记.md` · `05-实操练习包/` 里的实操手册 |

---

## 11. 演进触发条件（何时该换形态）

| 信号 | 动作 |
|---|---|
| 日志反复出现 `database is locked`，或第二个团队开始高频并发写 | SQLite → PostgreSQL（元数据迁出，artifacts 可暂留 NFS） |
| 磁盘长期 >70%，或需要多集群共享模型文件 | artifacts → MinIO/S3 |
| 要开放给多团队自注册模型 | 前面加 Nginx Basic Auth / 反向代理认证层 |
| 出现"训练完自动注册进 Jenkins 流水线"需求 | 正常，现有形态已支持（tracking_uri 指向 Service 即可） |

每一步演进都**不需要动使用方的记录代码**（只改 tracking_uri/环境变量），这也是当初选 MLflow 的好处。
