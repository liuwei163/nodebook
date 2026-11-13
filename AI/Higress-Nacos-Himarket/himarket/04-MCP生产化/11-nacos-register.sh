#!/bin/sh
# ---------------------------------------------------------------------------
# 11-nacos-register.sh —— MCP Server 的 Nacos 注册器（sidecar 长期运行）
#
# 为什么不手工在 Nacos 控制台点「新建实例」：
#   手工注册没有生命周期管理。Pod 重建后 IP 变了，控制台里那条记录还留着，
#   变成永远摘不掉的幽灵实例，网关会把流量打到不存在的 IP 上。
#
# 为什么用 sidecar 而不是 initContainer：
#   initContainer 只在启动时跑一次就退出，Pod 被删除时没人负责注销。
#   sidecar 和主容器同生共死，trap SIGTERM 就能完成注销。
#
# 为什么不写进应用代码：
#   MCP Server 应该只管 MCP 协议。注册是部署层的事，换注册中心（Nacos →
#   Consul → k8s Service）时不应该改业务代码。
#
# 环境变量（全部有默认值，可在 Deployment 里覆盖）：
#   NACOS_ADDR       nacos 地址，默认 nacos.himarket.svc.cluster.local:8848
#   NACOS_NAMESPACE  命名空间 ID，默认 ai-mcp（对应 McpBridge 的 nacosNamespaceId）
#   NACOS_GROUP      分组，默认 MCP_PROD
#   NACOS_USER/PASS  开启鉴权时必填（对应 McpBridge 的 authSecretName）
#   MCP_SERVICE_NAME 服务名，默认 mini-mcp
#   MCP_PORT         服务端口，默认 8765
#   NACOS_EPHEMERAL  true=临时实例（心跳保活，自愈快）；false=持久实例（Nacos 主动 TCP 探测）
#
# 退出码语义：任何致命错误直接 exit 1，让 k8s 重启这个 sidecar，
# 而不是带着「没注册成功」的状态一直挂着。
# ---------------------------------------------------------------------------
set -eu

NACOS_ADDR="${NACOS_ADDR:-nacos.himarket.svc.cluster.local:8848}"
NACOS_NAMESPACE="${NACOS_NAMESPACE:-ai-mcp}"
NACOS_GROUP="${NACOS_GROUP:-MCP_PROD}"
NACOS_USER="${NACOS_USER:-}"
NACOS_PASS="${NACOS_PASS:-}"
MCP_SERVICE_NAME="${MCP_SERVICE_NAME:-mini-mcp}"
MCP_PORT="${MCP_PORT:-8765}"
NACOS_EPHEMERAL="${NACOS_EPHEMERAL:-true}"
NACOS_WEIGHT="${NACOS_WEIGHT:-1}"

# POD_IP 由 Downward API 注入（status.podIP）
POD_IP="${POD_IP:?POD_IP 未注入，检查 Deployment 的 env.valueFrom.fieldRef}"

BASE="http://${NACOS_ADDR}"
# Nacos 3.x 保留 v1 兼容层；若你们版本已移除 v1，把下面四处 /v1/ 换成 /v2/
# 并把注册参数改成 JSON body（v2 是 POST /nacos/v2/ns/instance，body 为 JSON）。
INSTANCE_API="${BASE}/nacos/v1/ns/instance"
BEAT_API="${BASE}/nacos/v1/ns/instance/beat"
LOGIN_API="${BASE}/nacos/v1/auth/login"

# 元数据是网关侧做路由决策的依据。缺 transport 和 path，网关只能猜默认值，
# 猜错的表现就是「工具列表为空」——这个坑前面已经踩过一次。
METADATA="transport=streamable-http,path=/mcp,owner=ai-platform,version=1.2.0,env=prod,protocol=mcp"

TOKEN_PARAM=""
SERVICE_KEY="${NACOS_GROUP}@@${MCP_SERVICE_NAME}"
REGISTERED=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---- 鉴权：开启 auth 时先换 accessToken -----------------------------------
login() {
  # 注意：不能写成 `[ -z "$X" ] && return 0`。
  # set -e 下，当条件为假时整个 && 表达式返回 1，脚本会直接退出。
  if [ -z "$NACOS_USER" ]; then
    return 0
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    resp=$(curl -sS -m 5 -X POST "$LOGIN_API" \
      --data-urlencode "username=${NACOS_USER}" \
      --data-urlencode "password=${NACOS_PASS}" 2>/dev/null || true)
    token=$(printf '%s' "$resp" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
    if [ -n "$token" ]; then
      TOKEN_PARAM="accessToken=${token}"
      log "Nacos 鉴权成功"
      return 0
    fi
    log "等待 Nacos 鉴权接口就绪（第 ${i} 次）：$resp"
    sleep 3
  done
  log "Nacos 鉴权失败，退出"
  exit 1
}

# ---- 本地健康检查：主容器没起来之前不注册，避免把流量导进死 Pod -----------
local_healthy() {
  # 用 127.0.0.1 而不是 POD_IP：sidecar 和主容器共享网络命名空间
  curl -sS -m 2 -o /dev/null "http://127.0.0.1:${MCP_PORT}/healthz" 2>/dev/null
}

wait_local_health() {
  for i in $(seq 1 60); do
    if local_healthy; then
      log "本地 MCP 已就绪（127.0.0.1:${MCP_PORT}）"
      return 0
    fi
    sleep 2
  done
  log "等待本地 MCP 超过 120s 仍未就绪，退出交由 k8s 重启"
  exit 1
}

# ---- 注册 ----------------------------------------------------------------
register() {
  if [ "$REGISTERED" -eq 1 ]; then
    return 0
  fi
  for i in $(seq 1 10); do
    code=$(curl -sS -m 5 -o /tmp/reg.out -w '%{http_code}' -X POST "$INSTANCE_API" \
      --data-urlencode "serviceName=${MCP_SERVICE_NAME}" \
      --data-urlencode "groupName=${NACOS_GROUP}" \
      --data-urlencode "namespaceId=${NACOS_NAMESPACE}" \
      --data-urlencode "ip=${POD_IP}" \
      --data-urlencode "port=${MCP_PORT}" \
      --data-urlencode "weight=${NACOS_WEIGHT}" \
      --data-urlencode "ephemeral=${NACOS_EPHEMERAL}" \
      --data-urlencode "metadata=${METADATA}" \
      ${TOKEN_PARAM} 2>/dev/null || echo 000)

    if [ "$code" = "200" ] && [ "$(cat /tmp/reg.out)" = "ok" ]; then
      REGISTERED=1
      log "注册成功：${SERVICE_KEY} → ${POD_IP}:${MCP_PORT} (ephemeral=${NACOS_EPHEMERAL})"
      return 0
    fi
    log "注册失败（HTTP ${code}）：$(cat /tmp/reg.out 2>/dev/null) — 第 ${i} 次重试"
    sleep 3
  done
  log "注册连续失败 10 次，退出"
  exit 1
}

# ---- 心跳（仅临时实例需要）------------------------------------------------
beat() {
  [ "$NACOS_EPHEMERAL" = "true" ] || return 0
  body="{\"serviceName\":\"${SERVICE_KEY}\",\"ip\":\"${POD_IP}\",\"port\":${MCP_PORT},\"cluster\":\"DEFAULT\",\"weight\":${NACOS_WEIGHT},\"state\":\"UP\",\"metadata\":{\"transport\":\"streamable-http\",\"path\":\"/mcp\"}}"
  curl -sS -m 3 -o /dev/null -X PUT "$BEAT_API" \
    --data-urlencode "serviceName=${MCP_SERVICE_NAME}" \
    --data-urlencode "groupName=${NACOS_GROUP}" \
    --data-urlencode "namespaceId=${NACOS_NAMESPACE}" \
    --data-urlencode "beat=${body}" \
    ${TOKEN_PARAM} 2>/dev/null || log "心跳发送失败（将自动重试）"
}

# ---- 注销 ----------------------------------------------------------------
unregister() {
  if [ "$REGISTERED" -eq 0 ]; then
    return 0
  fi
  curl -sS -m 3 -o /dev/null -X DELETE "$INSTANCE_API" \
    --data-urlencode "serviceName=${MCP_SERVICE_NAME}" \
    --data-urlencode "groupName=${NACOS_GROUP}" \
    --data-urlencode "namespaceId=${NACOS_NAMESPACE}" \
    --data-urlencode "ip=${POD_IP}" \
    --data-urlencode "port=${MCP_PORT}" \
    --data-urlencode "ephemeral=${NACOS_EPHEMERAL}" \
    ${TOKEN_PARAM} 2>/dev/null || true
  REGISTERED=0
  log "已注销：${SERVICE_KEY} → ${POD_IP}:${MCP_PORT}"
}

cleanup() {
  log "收到退出信号"
  unregister
  exit 0
}
trap cleanup TERM INT

# ---- 主流程 --------------------------------------------------------------
login
wait_local_health
register

while true; do
  sleep 5
  if local_healthy; then
    beat
    if [ "$REGISTERED" -eq 0 ]; then
      # 之前因不健康被摘除，现在恢复了，重新挂回来
      register
    fi
  else
    if [ "$REGISTERED" -eq 1 ]; then
      log "本地健康检查失败，主动摘除流量"
      unregister
    fi
  fi
done
