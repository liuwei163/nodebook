#!/bin/bash
# =============================================================================
# 登记一个"已存在的模型文件"进 MLflow 注册表（占位 Run + 代理协议 source）
#
# 背景（关键认知）：
#   MLflow 的 Model Registry 要求模型版本必须来自某个 run 的 artifact 目录，
#   对"登记 NFS 上已有的模型"不友好。
#   本脚本用"占位 run + mlflow-artifacts:/ 前缀 source"绕开校验，
#   真实 NFS 路径记录在 storage_path tag 里。
#
#   为什么 source 必须用 mlflow-artifacts:/ 前缀：
#     只要客户端通过 HTTP 连 MLflow server，artifact_uri 就必然是
#     mlflow-artifacts:/... 形式（代理模式），跟 server 参数无关。
#     所以 source 填 /data/... 或 file:///... 都会被 "Invalid model version
#     source" 拒绝，只有 mlflow-artifacts:/0/<run_id>/artifacts/<模型名> 能过。
#
# 用法：
#   ./01-register-model.sh <模型名> <NFS上的模型路径> [描述]
#
# 示例：
#   ./01-register-model.sh DeepSeek-R1-Distill-Qwen-32B /mnt/nfs-temp/models/DeepSeek-R1-Distill-Qwen-32B "BF16 基座"
#
# 依赖：能访问 MLflow（先做端口转发）
#   kubectl -n ml-platform port-forward svc/mlflow 5000:5000
# =============================================================================
set -euo pipefail

MLFLOW_URL="${MLFLOW_URL:-http://127.0.0.1:5000}"
NS="${MLFLOW_NS:-ml-platform}"

# ---- 参数检查 ---------------------------------------------------------------
if [ $# -lt 2 ]; then
  echo "用法: $0 <模型名> <NFS路径> [描述]"
  echo "示例: $0 DeepSeek-R1-Distill-Qwen-32B /mnt/nfs-temp/models/DeepSeek-R1-Distill-Qwen-32B \"BF16 基座\""
  exit 1
fi

NAME="$1"
PATH_ON_NFS="$2"
DESC="${3:-NFS 上已有的模型}"

# ---- 前置检查 ---------------------------------------------------------------
if ! curl -sf -m 5 "$MLFLOW_URL/health" >/dev/null 2>&1; then
  echo "错误：连不上 MLflow ($MLFLOW_URL)"
  echo "先执行：kubectl -n $NS port-forward svc/mlflow 5000:5000"
  exit 1
fi

echo "==> 登记模型: $NAME"
echo "==> NFS 路径: $PATH_ON_NFS"

# ---- 1) 确保模型条目存在 ----------------------------------------------------
echo "==> [1/4] 确保模型条目存在 ..."
code=$(curl -s -o /tmp/rm_resp.json -w '%{http_code}' -X POST \
  "$MLFLOW_URL/api/2.0/mlflow/registered-models/create" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$NAME\"}")
if [ "$code" = "200" ]; then
  echo "    模型条目已创建"
elif grep -q "RESOURCE_ALREADY_EXISTS" /tmp/rm_resp.json; then
  echo "    模型条目已存在，跳过"
else
  echo "    创建模型条目失败 (HTTP $code)"; cat /tmp/rm_resp.json; exit 1
fi

# ---- 2) 创建占位 run --------------------------------------------------------
echo "==> [2/4] 创建占位 run ..."
start_time=$(date +%s%3N)
resp=$(curl -s -X POST "$MLFLOW_URL/api/2.0/mlflow/runs/create" \
  -H 'Content-Type: application/json' \
  -d "{\"experiment_id\":\"0\",\"start_time\":$start_time,\"tags\":[{\"key\":\"purpose\",\"value\":\"registry-anchor\"}]}")

run_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['run']['info']['run_id'])" 2>/dev/null)
if [ -z "$run_id" ]; then
  echo "    创建 run 失败，返回："; echo "$resp"; exit 1
fi
echo "    run_id = $run_id"

# ---- 3) 在 run 的 artifact 目录建占位子目录 ---------------------------------
echo "==> [3/4] 在 run 的 artifact 目录建占位子目录 ..."
kubectl -n "$NS" exec deploy/mlflow -- mkdir -p \
  "/data/artifacts/0/$run_id/artifacts/$NAME" 2>/dev/null || {
  echo "    无法在容器内建目录（检查 kubectl 权限和命名空间 $NS）"
  exit 1
}
echo "    占位目录已建: /data/artifacts/0/$run_id/artifacts/$NAME"

# ---- 4) 注册版本（source 用 mlflow-artifacts:/ 前缀）-------------------------
echo "==> [4/4] 注册模型版本 ..."
code=$(curl -s -o /tmp/mv_resp.json -w '%{http_code}' -X POST \
  "$MLFLOW_URL/api/2.0/mlflow/model-versions/create" \
  -H 'Content-Type: application/json' \
  -d "{
    \"name\": \"$NAME\",
    \"source\": \"mlflow-artifacts:/0/$run_id/artifacts/$NAME\",
    \"run_id\": \"$run_id\",
    \"description\": \"$DESC\",
    \"tags\": [
      {\"key\":\"storage_path\",\"value\":\"$PATH_ON_NFS\"},
      {\"key\":\"managed_by\",\"value\":\"register-model.sh\"}
    ]
  }")

if [ "$code" = "200" ]; then
  ver=$(python3 -c "import json; print(json.load(open('/tmp/mv_resp.json'))['model_version']['version'])" 2>/dev/null)
  echo "    ✅ 成功！模型 $NAME 版本 $ver 已登记"
else
  echo "    注册版本失败 (HTTP $code)"; cat /tmp/mv_resp.json; exit 1
fi

echo ""
echo "完成。浏览器查看: $MLFLOW_URL → Models 页"
echo "真实 NFS 路径已记在 storage_path tag: $PATH_ON_NFS"
