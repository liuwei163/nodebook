#!/usr/bin/env bash
# =============================================================================
# MLflow 元数据手动备份（SQLite 在线热备，无需停服务）
# 用法:  bash 02-运维与备份/02-mlflow-backup.sh [namespace]     默认 ns = ml-platform
#
# 原理: 调 python sqlite3 的 backup API，在服务运行时也能得到一致性副本，
#       落到 NFS 的 /data/backup/ 下，自动清理 30 天前的旧备份。
#
# ⚠ 认清备份边界:
#   - 能抵御: 数据库文件损坏、误删后需要找回
#   - 不能抵御: 整块 NFS 共享丢失（备份和原件在同一块盘上!）
#   => 每周至少一次把最新备份拷出 NFS（脚本末尾有命令），或依赖存储侧快照
# =============================================================================
NS="${1:-ml-platform}"
STAMP=$(date +%Y%m%d-%H%M%S)

# 1. 确保备份目录存在
kubectl -n "$NS" exec deploy/mlflow -- mkdir -p /data/backup || { echo "exec 失败，Pod 是否正常?"; exit 1; }

# 2. 在线热备（backup API 保证一致性）
kubectl -n "$NS" exec deploy/mlflow -- python -c "
import sqlite3
src = sqlite3.connect('/data/mlflow.db')
dst = sqlite3.connect('/data/backup/mlflow-${STAMP}.db')
src.backup(dst)
dst.close(); src.close()
print('backup-ok: /data/backup/mlflow-${STAMP}.db')
" || { echo "备份执行失败"; exit 1; }

# 3. 清理 30 天前的旧备份
kubectl -n "$NS" exec deploy/mlflow -- find /data/backup -name 'mlflow-*.db' -mtime +30 -delete

# 4. 备份有效性快检（integrity_check 应返回 ok）
kubectl -n "$NS" exec deploy/mlflow -- python -c "
import sqlite3
c = sqlite3.connect('/data/backup/mlflow-${STAMP}.db')
print('integrity_check:', c.execute('PRAGMA integrity_check').fetchone()[0])
c.close()
"

echo ""
echo "提示: 备份目前仍在同一块 NFS 上。建议每周把最新备份拷出 NFS:"
echo "  kubectl -n $NS cp deploy/mlflow:/data/backup/mlflow-${STAMP}.db ./mlflow-backup/"
