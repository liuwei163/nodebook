#!/usr/bin/env bash
# ============================================================
# HiMarket 离线镜像导入 —— 内网操作机侧执行
#
# 作用：docker load 后，把 images.txt 里的镜像按
#       “只替换 registry host、保留原路径”的规则 retag 到 Harbor 并 push。
#
# 例：opensource-registry.cn-hangzhou.cr.aliyuncs.com/higress-group/himarket-server:v0.8.2
#  →  harbor.corp.local/higress-group/himarket-server:v0.8.2
#
# 用法：
#   chmod +x import-to-harbor.sh
#   export HARBOR=harbor.corp.local
#   docker login "$HARBOR"
#   ./import-to-harbor.sh images.txt
#
# 可选：
#   DRY_RUN=1   只打印 retag 计划，不真正执行
#   HARBOR_USER / HARBOR_PASS  提供则自动创建缺失的 Harbor project
# ============================================================
set -euo pipefail

IMAGES_FILE=${1:-images.txt}
HARBOR=${HARBOR:-}
DRY_RUN=${DRY_RUN:-0}

[ -n "$HARBOR" ] || { echo "请先 export HARBOR=harbor.corp.local"; exit 1; }
[ -f "$IMAGES_FILE" ] || { echo "找不到镜像清单: $IMAGES_FILE"; exit 1; }
command -v docker >/dev/null || { echo "缺少 docker"; exit 1; }

# ---------- 1. 计算目标镜像 + 需要的 project ----------
declare -A PROJECTS=()
TARGETS=()

while read -r src; do
  [ -z "$src" ] && continue
  case "$src" in \#*) continue ;; esac

  # 去掉原 registry host（第一个 / 之前的部分），保留 path:tag
  if [[ "$src" == */* ]]; then
    path_tag=${src#*/}
  else
    path_tag="library/$src"
  fi

  dst="$HARBOR/$path_tag"
  TARGETS+=("$src|$dst")

  project=${path_tag%%/*}
  PROJECTS["$project"]=1
done < "$IMAGES_FILE"

echo "==> 目标 Harbor: $HARBOR"
echo "==> 需要存在的 project：${!PROJECTS[*]}"
echo ""

# ---------- 2. 自动建 project（有凭据时） ----------
if [ -n "${HARBOR_USER:-}" ] && [ -n "${HARBOR_PASS:-}" ] && [ "$DRY_RUN" != "1" ]; then
  for p in "${!PROJECTS[@]}"; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' \
      -u "$HARBOR_USER:$HARBOR_PASS" "https://$HARBOR/api/v2.0/projects?name=$p")
    if [ "$code" = "200" ]; then
      echo "    project $p 已存在"
    else
      curl -sk -u "$HARBOR_USER:$HARBOR_PASS" -X POST "https://$HARBOR/api/v2.0/projects" \
        -H 'Content-Type: application/json' \
        -d "{\"project_name\":\"$p\",\"public\":true}" >/dev/null \
        && echo "    project $p 已创建"
    fi
  done
  echo ""
else
  echo "!! 未提供 HARBOR_USER/HARBOR_PASS，请手工在 Harbor 建好以上 project"
  echo ""
fi

# ---------- 3. load + retag + push ----------
if [ -f images.tar ] && [ "$DRY_RUN" != "1" ]; then
  echo "==> docker load images.tar"
  docker load -i images.tar
  echo ""
fi

fail=0
for pair in "${TARGETS[@]}"; do
  src=${pair%%|*}
  dst=${pair##*|}

  echo "==> $src"
  echo " -> $dst"

  if [ "$DRY_RUN" = "1" ]; then
    continue
  fi

  if ! docker image inspect "$src" >/dev/null 2>&1; then
    echo "    !! 本地找不到该镜像，跳过（确认 images.tar 已 load）"
    fail=$((fail+1))
    continue
  fi

  docker tag "$src" "$dst"
  if docker push "$dst"; then
    echo "    ok"
  else
    echo "    !! push 失败"
    fail=$((fail+1))
  fi
done

echo ""
if [ "$fail" -gt 0 ]; then
  echo "!! 有 $fail 个镜像处理失败，请逐条排查后再部署"
  exit 1
fi

echo "全部完成。下一步：按 Runbook 第 4 节修改 values.yaml，再 ./install.sh"
