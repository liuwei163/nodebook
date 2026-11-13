# 工作区索引

> 2026-11-13 重组：按「一个主题 = 一个目录」组织，文件名的两位编号 = 所属主题。
> **同编号 = 同一组配套物料**：找到手册，就能在旁边找到它的脚本和清单。
> 文档里的 `kubectl` / `bash` / `python3` 命令默认在仓库根目录执行。

## 一对一对照表

| 编号 · 目录 | 主文档（讲什么） | 配套可执行工具 | 配套 K8s 清单 |
|---|---|---|---|
| **01 · 部署与模型登记** | `01-MLflow离线部署与模型登记.md`：离线部署 4 个坑、65GB 大模型登记、NFS 落盘故障根因与修复 | `01-register-model.sh`：把 NFS 上已有模型登记进注册表 | `01-mlflow.yaml`：主部署（PV/PVC/Deployment/Service + exporter sidecar） |
| **02 · 运维与备份** | `02-MLflow运维手册.md`：五大职责、巡检/备份/恢复 SOP、容量与升级 | `02-mlflow-daily-check.sh` 一键巡检、`02-mlflow-backup.sh` SQLite 在线热备 | `02-mlflow-backup-cronjob.yaml` 每日自动备份 |
| **03 · 监控接入** | `03-MLflow监控接入手册.md`：13 指标 / 10 面板 / 6 告警，监控唯一权威口径 | `03-mlflow-exporter.py` 导出器源稿、`03-sync-exporter-configmap.py` 源稿同步 | `03-mlflow-exporter-configmap.yaml`、`03-mlflow-podmonitor.yaml`、`03-mlflow-servicemonitor.yaml`、`03-mlflow-prometheus-rbac.yaml`、`03-mlflow-rules.yaml`、`03-mlflow-grafana-dashboard.json`、`03-grafana-lite.yaml` |
| **04 · 推理性能实测** | `04-DeepSeek32B推理性能实测报告.md`：昇腾 910B×8 压测原始数据、6.5 倍提速、PD 分离 vs 共置对照 | `04-npu_bench.py` 纯标准库流式压测 | `04-dk32-colocated-tp8.yaml` 共置 TP8 部署清单 |
| **05 · 实操练习包** | `05-MLflow上手实操手册.md` → `05-MLflow真模型实操手册.md` → `05-脚本白话讲解.md` → `05-Docker镜像打包完整流程.md`（练习 → 进阶 → 逐段讲解 → 镜像打包） | `05-practice.py`、`05-train_real.py`、`05-load_real.py`、`05-Dockerfile.practice` | 无（训练客户端，记录写进 01 部署的 MLflow） |
| **06 · 规划与面试** | `06-MLOps两层落地实施手册.md` 规划蓝本、`06-DeepSeek32B推理优化面试材料.md` 项目叙事、`06-AI-Infra与MLOps面试题库.md` 题库总纲 | — | — |

## 跨组依赖（最容易找漏的 4 条）

1. `01-mlflow.yaml` 是**唯一的主部署清单**。02 的运维对象、03 的 exporter sidecar 都定义在它里面；改监控或备份要回 01 组改这个文件。
2. 03 组改完 `03-mlflow-exporter.py` 后，必须跑 `03-监控接入/03-sync-exporter-configmap.py`，把源稿同步进 `03-mlflow-exporter-configmap.yaml` 的内嵌副本，否则 Pod 里跑的还是旧代码。ConfigMap 的 data key 与容器内路径保持 `mlflow-exporter.py` 不变。
3. 05 组的练习脚本通过 `MLFLOW_TRACKING_URI` 连到 01 组部署的 MLflow；`confusion_matrix.png` 是训练产物示例，与脚本运行时生成的文件同名，因此不加编号。
4. 04 组的实测数据是 06 组面试叙事的数据来源；06 组手册头部已标注「规划蓝本 vs 昇腾实测」的勘误关系。

## 旧路径对照（历史日志里仍会看到）

| 旧目录 | 现在去哪找 |
|---|---|
| `docs/` | 06 组（规划/面试）+ 01~04 各主题目录（手册已与物料同组） |
| `manifests/` | 01~04 各主题目录 |
| `scripts/` | 01~05 各主题目录 |
| `mlflow-hands-on/` | `05-实操练习包/` |
| `jenkins/`、`values/` | 已移除；Jenkins/GitLab 物料备份在 `C:\Users\Windows\WorkBuddy\cicd-jenkins-gitlab-backup-20261113` |

`.workbuddy/memory/` 为项目工作记录，保留历史原文，其中的旧路径按上表解释。
本次重组前的完整快照：`C:\Users\Windows\WorkBuddy\cicd-backup-before-reorg-20261113`。
