# MLflow 监控接入手册（Prometheus + Grafana）

> 目标：给 MLflow 补上"能被看见"的监控——服务健康、磁盘水位、训练状态、台账规模，
> Grafana 出图 + 6 条告警规则 + 完整的日常运维与演进规划。
>
> **为什么需要额外做一个导出器**：MLflow server 自身**不提供** Prometheus `/metrics`
> 接口，直接抓它什么都抓不到。方案 = 给 Pod 加一个 sidecar 导出器
> （纯 Python 标准库，零新增镜像和依赖，离线可用）。
>
> **当前状态（2026-11-09）**：✅ 已全部落地——抓取链路绿 UP、13 个指标入库、
> 看板 10 面板、告警规则 6 条。本文档是这套监控的唯一权威口径。

---

## 〇、适用场景判断（先盘点再动手）

```bash
kubectl get ns | grep -iE "monitor|prometheus|grafana|cattle|obs"
kubectl get pods -A | grep -iE "prometheus|grafana|exporter" | head -20
```

- **有 Prometheus + Grafana** → 走本文档全流程
- **完全没有** → 直接跳第七节：轻量告警方案，以及"是否为整个 AI 平台铺监控"的评估

---

## 一、架构与指标清单

### 1.1 数据链路（实测验证版）

```
┌──────────────────────── mlflow Pod ────────────────────────┐
│  主容器 mlflow (:5000)          sidecar exporter (:9110)   │
│  ├─ /health  ←──── GET 探活（计时） ──┤                     │
│  └─ /data (NFS) ←─ statvfs 量磁盘 + sqlite 只读查计数 ──┤   │
│                                  │ /metrics（Prom 格式）    │
└──────────────────────────────────┼─────────────────────────┘
        PodMonitor CR 声明抓取 ↓    （注解抓取在本集群无效，见 3.1）
        Prometheus 每 30s 抓 :9110/metrics → 保留 4h
        Grafana 读 Prometheus 出图（10 面板）+ PrometheusRule 6 条告警
```

### 1.2 指标清单（13 个，按四黄金信号归类）

| 指标 | 含义 | 黄金信号 | 用途 |
|---|---|---|---|
| `mlflow_up` | /health 探活 1/0 | 错误 | 服务可用性告警 |
| `mlflow_health_probe_duration_seconds` | 探活请求耗时(秒) | 延迟 | 性能劣化前兆（>1s 告警） |
| `mlflow_disk_used_ratio` | /data 使用率 | 饱和度 | 对接 70/85/90 三级水位红线 |
| `mlflow_disk_used_bytes` / `_total_bytes` | 已用/总量字节 | 饱和度 | 增速计算、容量规划 |
| `mlflow_experiments_total` | 活跃实验数 | - | 平台使用广度 |
| `mlflow_runs_total` | 活跃 run 数 | 流量 | 增速 = 训练提交频率 |
| `mlflow_runs_by_status` | 按 status 细分 run 数 | 错误/流量 | FAILED=失败率；RUNNING=当前负载 |
| `mlflow_run_duration_seconds_avg` | 已结束 run 平均时长(秒) | - | 训练时长基线 |
| `mlflow_registered_models_total` | 注册模型数 | - | 台账种类数 |
| `mlflow_model_versions_total` | 模型版本数 | - | 台账深度 |
| `mlflow_model_versions_created_24h` | 最近 24h 新增版本数 | 流量 | 登记频率（业务层） |

> 训练成功率由 `FINISHED/(FINISHED+FAILED)` 推导。业务层指标全部由
> sqlite 只读查询推导——**库本身就是事件账本**，不改 MLflow server 任何代码。
> 注意口径：`disk_*` 量的是**整块 NFS 共享盘**，不只 MLflow 的数据。

### 1.3 01-部署与模型登记/01-mlflow.yaml 变更对照（监控相关共 3 处新增）

> **脚本双份机制与同步流程**：`03-监控接入/03-mlflow-exporter.py` 是源稿（进 git），
> 部署的是 `03-监控接入/03-mlflow-exporter-configmap.yaml` 内嵌副本（挂载进 sidecar 运行）。
> **改逻辑的标准流程（已自动化）**：
> 改源稿 → `python3 03-监控接入/03-sync-exporter-configmap.py` →
> apply 新 ConfigMap → `kubectl -n ml-platform rollout restart deploy/mlflow`。
> 重启不能省：挂载文件会自动更新，但进程不会重载。

- 【监控新增①】Pod 注解：`prometheus.io/scrape/port`（本集群实际无效，保留为跨集群兼容）
- 【监控新增②】exporter sidecar 容器（复用 mlflow 镜像、9110 端口、共享 /data）
- 【监控新增③】`exporter-script` ConfigMap 卷（**必须先 apply ConfigMap**，
  否则 Pod 卡 `CreateContainerConfigError`）

yaml 内部已用【监控新增①/②/③】标注，其余内容（PV/PVC、落盘修复、Service）
与监控无关。

---

## 二、部署与更新

### 2.1 全新部署（完整顺序）

```bash
# ① ConfigMap 必须最先（sidecar 靠它挂载脚本）
kubectl apply -f 03-监控接入/03-mlflow-exporter-configmap.yaml
# ② 部署清单（Recreate 自动重启）
kubectl -n ml-platform apply -f 01-部署与模型登记/01-mlflow.yaml
# ③ PodMonitor 抓取声明（本集群注解抓取无效，必做）
kubectl apply -f 03-监控接入/03-mlflow-podmonitor.yaml
# ④ RBAC 授权（PodMonitor pool 出现但 0 target 时需要，见 2.3）
kubectl apply -f 03-监控接入/03-mlflow-prometheus-rbac.yaml
# ⑤ 告警规则
kubectl apply -f 03-监控接入/03-mlflow-rules.yaml
# ⑥ 验证
kubectl -n ml-platform get pods -l app=mlflow          # 2/2 READY
kubectl -n ml-platform exec deploy/mlflow -c exporter -- \
  python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:9110/metrics').read().decode())"
# Prometheus Targets 页搜 mlflow → podMonitor/ml-platform/mlflow-exporter/0 (1/1 up)
```

### 2.2 更新导出器（改采集逻辑时）

```bash
python3 03-监控接入/03-sync-exporter-configmap.py     # 本机：源稿同步进 ConfigMap
kubectl apply -f 03-监控接入/03-mlflow-exporter-configmap.yaml
kubectl -n ml-platform rollout restart deployment/mlflow   # 必须重启
```

### 2.3 排查决策树：PodMonitor 不生效（Targets 无 mlflow）

```bash
# ① 对象存在吗
kubectl -n ml-platform get podmonitor
# ② 决定性检查：Prometheus 加载的配置里有这个 job 吗
curl -s localhost:9090/api/v1/status/config | python3 -c "
import sys,json
c=json.load(sys.stdin)['data']['yaml']
hits=[l.strip() for l in c.splitlines() if 'mlflow' in l.lower()]
print('job FOUND' if hits else 'job NOT FOUND')
[print(' ', h) for h in hits]"
# ③ Operator 日志（② NOT FOUND 时）
kubectl get pods -A | grep -i operator
kubectl -n <operator-ns> logs <pod> --tail=300 | grep -iE "mlflow|podmonitor|error"
```

| 结果 | 结论 | 动作 |
|---|---|---|
| ① 无 | 没 apply 成功 | 重新 apply |
| ② 有 job 但 pool 空 | 发现层问题（**最大嫌疑 RBAC**） | `kubectl auth can-i list pods -n ml-platform --as=system:serviceaccount:kube-system:cmss-kcs-prometheus` → no 则 apply 03-监控接入/03-mlflow-prometheus-rbac.yaml |
| ② 无 job | Operator 不认 PodMonitor | 降级 `kubectl apply -f 03-监控接入/03-mlflow-servicemonitor.yaml`（含 Service 补丁，幂等无损） |

---

## 三、Prometheus 抓取机制与集群实测结论

### 3.1 本集群监控栈画像（2026-11-06/09 实测）

- **形态**：Prometheus Operator 管理（`kube-system/cmss-kcs-prometheus`，
  1/1 Ready、Reconciled=True，云平台定制版，非标准 kube-prometheus-stack）
- **抓取风格**：Targets 页全部 scrape pool 为 `serviceMonitor/` 前缀
  （kubelet/kube-proxy 都是），**Pod 注解抓取机制不存在**
- **有效抓取路径**：PodMonitor CR（`podMonitorSelector: {}` = 全量选择）
  → 已实测打通，pool `podMonitor/ml-platform/mlflow-exporter/0 (1/1 up)`
- **PrometheusRule**：`ruleSelector: {}` = 全量加载，**label 随意，apply 即生效**
- **关键参数**：`retention: 4h`（趋势查询窗口别超 4h）、`scrapeInterval: 30s`
- **RBAC**：Prometheus SA 默认可能只能读 kube-system，跨 ns 需
  `03-监控接入/03-mlflow-prometheus-rbac.yaml`（ml-platform 内 Role+RoleBinding，纯新增不动平台资源）

### 3.2 Grafana 看板（10 面板）

导入 `03-监控接入/03-mlflow-grafana-dashboard.json`（uid `mlflow-ops`，重复导入选覆盖），
数据源选本集群 Prometheus。面板：服务状态 / 磁盘水位仪表盘(70/85/90 三档) /
实验数 / 版本数 / 磁盘趋势 / run 趋势 / **run 状态分布 / 探活延迟 / 24h 新增版本 / 平均训练时长**。

> **集群没装 Grafana 时的替代**（2026-11-09 实况）：Prometheus 自带 Graph/Table
> + Alerts 页功能上完全够用，只是没有常驻大屏。想补看板用轻量方案
> `03-监控接入/03-grafana-lite.yaml`（单实例、零外部依赖、provisioning 自动装载数据源
> 和看板，NodePort 30300 访问）——前置是导入一个 grafana 镜像到 Harbor，
> 步骤见该 yaml 头部注释。另务必确认 Alertmanager 是否存在
> （`kubectl get alertmanager -A`）——没有它告警只在 UI 显示、不会主动通知。

### 3.3 告警规则（6 条，`03-监控接入/03-mlflow-rules.yaml`）

| 告警 | 表达式 | 级别 | 黄金信号 |
|---|---|---|---|
| MlflowServerDown | `mlflow_up == 0` 持续 2m | critical | 错误 |
| MlflowMetricsMissing | `absent(mlflow_up)` 持续 10m | warning | 错误（导出器失联兜底） |
| MlflowDiskHigh | `used_ratio > 0.85` 持续 10m | warning | 饱和度 |
| MlflowDiskCritical | `used_ratio > 0.90` 持续 10m | critical | 饱和度 |
| MlflowProbeSlow | `probe_duration > 1s` 持续 5m | warning | 延迟 |
| MlflowTrainingFailed | `increase(runs_by_status{status="FAILED"}[1h]) > 0` | info | 业务事件 |

apply 后验证：Prometheus UI → **Alerts** 页列出 6 条且 `inactive`（未触发属正常）。
各条完整表达式与处置提示见 yaml 内注释（单一口径原则，本文档不重复维护）。

---

## 四、验收清单

```bash
# ① exporter 在线且 13 个指标齐全（exec 拉 /metrics，mlflow_up 1）
# ② Prometheus Targets：podMonitor/ml-platform/mlflow-exporter/0 (1/1 up)
# ③ Graph 查 {__name__=~"mlflow_.*"} → Result series: 8+（时间序列按标签拆分后更多）
# ④ Grafana 10 面板出图（stat 类秒有值，趋势类从部署时刻积累，窗口≤4h）
# ⑤ 告警演练：delete Pod → MlflowServerDown 触发 → Pod 恢复后回到 inactive
# ⑥ 业务联动：跑一次训练/登记一个版本 → runs_total 或 created_24h 变化
```

---

## 五、完整监控流程规划（核心章节）

### 5.1 覆盖现状（五层模型定位）

| 层 | 内容 | MLflow 现状 |
|---|---|---|
| 业务层 | 训练成功率、登记频率、台账规模 | ✅ 由 13 指标推导 |
| 应用层 | 四黄金信号（延迟/流量/错误/饱和度） | ✅ 四项都有对应物（请求级 RED 除外） |
| 组件层 | NFS · 数据库 · Jenkins · vLLM | ⚠️ 部分（巡检脚本 + statvfs） |
| K8s 层 | kube-state-metrics · cAdvisor | ❌ 未接入自建看板 |
| 基础设施层 | node_exporter · GPU(DCGM) | ❌ 未接入 |

### 5.2 日常运维节奏

| 节奏 | 动作 | 依据 |
|---|---|---|
| 每日（1 分钟） | 瞄一眼看板：状态灯是否 UP、水位曲线斜率、run 状态分布 | 10 面板 |
| 实时 | 告警来了按 5.3 响应 | 6 条规则 |
| 每周 | 核对备份 CronJob 成功记录；算一次磁盘周增速，外推到 85% 红线的剩余天数 | disk_used_bytes |
| 每月 | 评审指标覆盖率（5.5 自查表）、告警触发记录（有没有"狼来了"要调阈值） | 本节 |
| 每季度 | 备份恢复演练（备份≠可恢复） | 运维手册第 3 节 |

### 5.3 告警响应流程（收到告警后干什么）

```
告警触发
├─ MlflowServerDown (critical)
│   ① kubectl -n ml-platform get pods -l app=mlflow   → Pod 在不在
│   ② describe pod 看事件（OOMKilled/镜像拉取/挂载失败）
│   ③ 恢复不了 → 运维手册第 8 节 SOP；事后在 Grafana 看挂之前的探活延迟曲线找前兆
├─ MlflowDiskHigh / Critical (warning/critical)
│   ① du 定位大文件：pod 内 /data/* + 节点上整个共享盘（口径见 1.2）
│   ② 明确是 MLflow 增长还是共享盘他人数据 → 决定清理/扩容/找归属
│   ③ Critical 时警惕写满：备份 CronJob 也会写这个盘
├─ MlflowProbeSlow (warning)
│   NFS 抖动 / sqlite 写锁竞争 / 宿主机负载 —— 观察 24h，持续劣化再深挖
├─ MlflowTrainingFailed (info)
│   MLflow UI 查失败 run 的报错；是业务问题不是平台问题，转发给训练负责人
└─ MlflowMetricsMissing (warning)
    抓取链路问题，按 2.3 决策树走
每次 critical 处理完写 3 行复盘：现象 / 根因 / 哪个指标能更早发现
```

### 5.4 缺口与演进路线图（按"哪个组件挂了最痛"排序）

| 优先级 | 项目 | 解决什么 | 成本 |
|---|---|---|---|
| P0 | 备份任务监控（CronJob 指标+告警） | 备份静默失败三个月没人知 | 半天 |
| P1 | 前置代理：**已有 Higress（Envoy 内核）**，把 MLflow 挂到网关路由后面即可 | QPS、p95/p99 延迟、5xx 率、请求字节数——请求级 RED 全套（方案见 5.7） | 0.5~1 天 |
| P2 | SQLite → PostgreSQL + postgres_exporter | 连接池饱和、锁等待、慢查询（用量上来后的必做项） | 2~3 天+评审 |
| P3 | 日志聚合（Loki/ELB） | "指标发现异常→日志定位原因"那条腿 | 2~3 天 |
| P4 | 平台化扩展：vLLM/DCGM/Jenkins 复制本模式 | 五层模型逐层点亮 | 每组件 0.5~1 天 |

> 汇报口径：讲清取舍链条——离线环境 → 无 Ingress 指标栈 → sqlite 推导业务指标
> → 用量触发后迁 PG。**知道自己缺什么、为什么缺、什么时候补**，比"配了监控"值钱。

### 5.5 指标覆盖自查框架（RED + USE 合并版）

每接入一个新服务，对着清单打勾：

```
RED（在线服务）：
  Requests —— 谁在用、频率多少         （MLflow：✅ 推导值 / ❌ 请求级 QPS 等 P1）
  Errors   —— 失败了多少               （MLflow：✅ up + FAILED / ❌ 5xx 率等 P1）
  Duration —— 每次多快（看 p95 不看均值）（MLflow：✅ 合成探针 / ❌ 请求级等 P1）
USE（每个资源）：
  Utilization —— 用了多少              （✅ 磁盘；❌ CPU/内存/连接池）
  Saturation  —— 排队了吗              （❌ worker 忙碌、锁等待 → P2）
  Errors      —— 资源自身报错           （✅ 探针失败即体现）
```

### 5.6 新组件接入模板（把 MLflow 模式复制到 vLLM/Jenkins/NFS）

1. 查该组件**有没有原生 /metrics**（vLLM/Jenkins 有，NFS 服务端要另想）→ 有则跳到 3
2. 没有 → 照 `03-监控接入/03-mlflow-exporter.py` 写一个 sidecar 导出器（改数据源即可）
3. 部署：ConfigMap(如需) → Service/PodMonitor 抓取声明 → 验证 Targets 绿 UP
4. 看板：复制 mlflow-ops 的 uid 模式建新面板组；告警：照 `03-监控接入/03-mlflow-rules.yaml` 写
   该服务的 Down/Slow/资源三类规则
5. 更新本手册：组件名、指标表、日常节奏加一行

### 5.7 请求级 RED 方案：Higress 网关（P1，待实施）

集群已有 Higress（Envoy 内核），把 MLflow 挂到网关路由后，代理层自动产出请求级指标：

| 需求 | Envoy/Higress 指标族（以实际 /stats/prometheus 输出为准） | PromQL 思路 |
|---|---|---|
| QPS | `envoy_cluster_upstream_rq_total` / per-route rq 计数 | `rate(...[1m])` |
| 延迟直方图 | `envoy_cluster_upstream_rq_time_bucket` | `histogram_quantile(0.95, sum by (le) (rate(...[5m])))` |
| 状态码分布 | `envoy_cluster_upstream_rq_xx{envoy_response_code=...}` | 5xx 率 = 5xx/total |
| 请求字节数 | `envoy_cluster_upstream_cx_rx_bytes_total` 等 | `rate(...[1m])` 看带宽峰值 |

实施要点：
1. 先确认 Higress 网关的 stats 端口是否已被本集群 Prometheus 抓取
   （Targets 页搜 higress；本集群是 ServiceMonitor 原生栈，用 ServiceMonitor
   指向 higress-gateway 的监控端口）
2. 在 Higress 配置 mlflow 路由（→ service mlflow.ml-platform:5000），
   **大 artifact 上传场景**要放宽路由超时和请求体限制，并压测验证
3. 客户端跟踪地址从直连 Service 改为网关地址（`mlflow.set_tracking_uri`），
   切换期直连与网关并存，回退零成本
4. 上线后在看板加 RED 面板 + 告警加 5xx 率规则
5. 已知局限：端点级细分（按 API 路径）需要按路径拆路由才能实现，
   先拿整服务粒度就够用；DB 连接池/worker 饱和度仍属 P2 范围

---

## 六、和已有体系的衔接

| 层 | 谁负责 | 工具 |
|---|---|---|
| 服务可用性 | exporter（mlflow_up + probe_duration） | Prometheus 告警 |
| 磁盘容量 | exporter（disk_*）+ 巡检脚本 | 告警 + 每日看板 |
| 业务规模 | exporter（实验/run/版本/状态计数） | Grafana 趋势图 |
| 数据安全 | 备份 CronJob + 每周拷出 NFS | 运维手册第 3 节（P0 待补监控） |
| 故障处置 | 运维手册第 8 节 SOP | 告警响应 5.3 引用 |

---

## 七、如果集群里根本没有 Prometheus（两条路）

1. **轻量先行**：`02-运维与备份/02-mlflow-daily-check.sh` 退出码 1 时加 curl 推送企业微信/邮件，
   10 分钟解决"挂了没人知道"
2. **统一铺监控（中期）**：kube-prometheus-stack chart + 镜像导入内网，
   一次部署顺便纳管 kthena/vLLM/Jenkins——不为 MLflow 单独铺一套
