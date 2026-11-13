#!/usr/bin/env bash
# =============================================================================
# MLflow 日常巡检脚本（只读，不改变任何状态）
# 用法:  bash 02-运维与备份/02-mlflow-daily-check.sh [namespace]
# 默认:  namespace = ml-platform
# 退出码: 0 = 全部通过   1 = 存在异常项（可直接接告警）
# 检查项: Pod状态/重启 | /health | 磁盘水位 | 错误日志 | 备份新鲜度 | artifact大户
# =============================================================================
NS="${1:-ml-platform}"
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
FAIL=0

check() {  # check <检查项> <0通过/1异常> <详情>
  if [ "$2" = "0" ]; then
    printf '%s\n' "${GREEN}[通过]${NC} $1   $3"
  else
    printf '%s\n' "${RED}[异常]${NC} $1   $3"; FAIL=1
  fi
}

echo "=== MLflow 日常巡检  ns=$NS  $(date '+%F %T') ==="

# ---- 1. Pod 状态与重启次数 --------------------------------------------------
POD_LINE=$(kubectl -n "$NS" get pods -l app=mlflow --no-headers 2>/dev/null | head -1)
if [ -z "$POD_LINE" ]; then
  check "Pod 存在" 1 "没找到 app=mlflow 的 Pod"
else
  POD=$(echo "$POD_LINE" | awk '{print $1}')
  READY=$(echo "$POD_LINE" | awk '{print $2}')
  STATUS=$(echo "$POD_LINE" | awk '{print $3}')
  RESTARTS=$(echo "$POD_LINE" | awk '{print $4}')
  [ "$STATUS" = "Running" ] && [ "$READY" = "1/1" ]
  check "Pod 状态" $? "$POD  ready=$READY  status=$STATUS"
  [ "$RESTARTS" -lt 3 ] 2>/dev/null
  check "重启次数" $? "restarts=$RESTARTS（>=3 需 kubectl logs --previous 查原因）"
fi

# ---- 2. 健康检查（Pod 内自访问 /health，不依赖集群外网络）--------------------
HEALTH=$(kubectl -n "$NS" exec deploy/mlflow -- python -c \
  "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:5000/health',timeout=5).status)" 2>/dev/null)
[ "$HEALTH" = "200" ]
check "健康检查 /health" $? "HTTP=$HEALTH"

# ---- 3. 磁盘水位（红线: 70 预警 / 85 处置）----------------------------------
DF_LINE=$(kubectl -n "$NS" exec deploy/mlflow -- df -P /data 2>/dev/null | tail -1)
USED_PCT=$(echo "$DF_LINE" | awk '{print $5}' | tr -d '%')
if [ -z "$USED_PCT" ]; then
  check "磁盘水位" 1 "df 取值失败（PVC 是否正常挂载?）"
elif [ "$USED_PCT" -ge 85 ]; then
  check "磁盘水位" 1 "已用 ${USED_PCT}%  >=85% 立即处置：清理废弃run+gc，或找存储组扩容"
elif [ "$USED_PCT" -ge 70 ]; then
  printf '%s\n' "${YELLOW}[预警]${NC} 磁盘水位   已用 ${USED_PCT}%  >=70% 安排清理"
else
  check "磁盘水位" 0 "已用 ${USED_PCT}%"
fi

# ---- 4. 错误日志扫描（重点: database is locked 是换 PostgreSQL 的信号）--------
ERRS=$(kubectl -n "$NS" logs deploy/mlflow --tail=300 2>/dev/null \
  | grep -iE "error|locked|traceback" | grep -viE "0 errors|errorlog" | tail -5)
[ -z "$ERRS" ]
check "错误日志(近300行)" $? "$(echo "$ERRS" | head -2)"

# ---- 5. 备份新鲜度（超过 48 小时没新备份 = 备份链断了）-------------------------
LATEST=$(kubectl -n "$NS" exec deploy/mlflow -- ls -t /data/backup 2>/dev/null | head -1)
if [ -z "$LATEST" ]; then
  check "备份新鲜度" 1 "未发现 /data/backup —— 立即确认备份 CronJob 是否在跑"
else
  AGE_H=$(kubectl -n "$NS" exec deploy/mlflow -- python -c \
    "import time,os;p='/data/backup/$LATEST';print(int((time.time()-os.path.getmtime(p))/3600))" 2>/dev/null)
  [ -n "$AGE_H" ] && [ "$AGE_H" -lt 48 ] 2>/dev/null
  check "备份新鲜度" $? "最新备份: $LATEST（${AGE_H:-?} 小时前）"
fi

# ---- 6. artifact 占用 Top5（定位谁在吃磁盘）----------------------------------
echo "---- artifact 占用 Top5 ----"
kubectl -n "$NS" exec deploy/mlflow -- sh -c \
  "du -sk /data/artifacts/* 2>/dev/null | sort -rn | head -5" 2>/dev/null \
  | awk '{printf "  %8.1f MB  %s\n", $1/1024, $2}'

echo "---- 巡检结论 ----"
if [ "$FAIL" = "0" ]; then
  printf '%s\n' "${GREEN}全部通过${NC}"
  exit 0
else
  printf '%s\n' "${RED}存在异常项，按《02-运维与备份/02-MLflow运维手册.md》第 8 节应急 SOP 处置${NC}"
  exit 1
fi
