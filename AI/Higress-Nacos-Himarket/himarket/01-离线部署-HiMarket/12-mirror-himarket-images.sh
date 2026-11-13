#!/usr/bin/env bash
# ============================================================
# HiMarket 离线镜像搬运 —— 摆渡机（有外网）侧执行
#
# 作用：用 helm template 渲染 chart，抓出全部 image 引用，
#       逐个 pull 后 docker save 成一个 tar 包。
#
# 用法：
#   chmod +x 12-mirror-himarket-images.sh
#   TAG=v0.8.2 ./12-mirror-himarket-images.sh
#
# 可覆盖的环境变量：
#   TAG           HiMarket 镜像版本，默认 v0.8.2（前一版 v0.8.1）
#   CHART_ROOT    含 himarket/ nacos/ 解包目录的父目录，默认当前目录
#   HIGRESS_DIR   本地化的 higress chart 路径，默认 $CHART_ROOT/charts/higress
#   PLATFORM      目标架构，默认 linux/amd64（KCS worker 为 x86_64）
#   OUT           输出目录，默认 $PWD/out
# ============================================================
set -euo pipefail

TAG=${TAG:-v0.8.2}
CHART_ROOT=${CHART_ROOT:-$PWD}
HIGRESS_DIR=${HIGRESS_DIR:-$CHART_ROOT/charts/higress}
PLATFORM=${PLATFORM:-linux/amd64}
OUT=${OUT:-$PWD/out}

command -v helm   >/dev/null || { echo "缺少 helm";   exit 1; }
command -v docker >/dev/null || { echo "缺少 docker"; exit 1; }

mkdir -p "$OUT"
RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

echo "==> 渲染 chart（使用原始默认仓库地址，便于公网拉取）"

HIMARKET_CHART="$CHART_ROOT/himarket"
NACOS_CHART="$CHART_ROOT/nacos"

[ -f "$HIMARKET_CHART/Chart.yaml" ] || { echo "找不到 himarket chart: $HIMARKET_CHART"; exit 1; }

# 注意：这里刻意不 --set hub，让渲染结果保持官方公网 registry，
#       否则会渲染出 Harbor 地址，摆渡机根本拉不到。
helm template himarket "$HIMARKET_CHART" -n himarket \
  --set frontend.image.tag="$TAG" \
  --set admin.image.tag="$TAG" \
  --set server.image.tag="$TAG" \
  --set sandbox.image.tag="$TAG" \
  > "$RENDER_DIR/himarket.yaml"

if [ -f "$NACOS_CHART/Chart.yaml" ]; then
  helm template nacos "$NACOS_CHART" -n himarket > "$RENDER_DIR/nacos.yaml" \
    || echo "!! nacos chart 渲染失败，可能需要 --set 占位参数，请手工补齐后重跑"
fi

if [ -f "$HIGRESS_DIR/Chart.yaml" ]; then
  helm template higress "$HIGRESS_DIR" -n higress-system > "$RENDER_DIR/higress.yaml" \
    || echo "!! higress chart 渲染失败，请检查是否缺少 dependencies"
else
  echo "!! 未找到 higress chart：$HIGRESS_DIR（离线部署必须本地化，见 Runbook 2.2）"
fi

echo "==> 提取镜像清单"
grep -hoE 'image:[[:space:]]*"?[^"[:space:]]+' "$RENDER_DIR"/*.yaml 2>/dev/null \
  | sed -E 's/image:[[:space:]]*"?//' \
  | grep -v '{{' \
  | grep -vE '^(none|null|\$)' \
  | sort -u > "$OUT/images.txt"

COUNT=$(wc -l < "$OUT/images.txt")
echo "==> 共 $COUNT 个镜像："
cat "$OUT/images.txt"

if [ "$COUNT" -lt 6 ]; then
  echo ""
  echo "!! 镜像数量异常偏少（预期 >= 6，含 himarket×4 + mysql + nacos + higress + redis）"
  echo "!! 请检查各 chart 是否渲染成功，必要时手工从 values.yaml 补全"
fi

echo "==> 开始拉取（$PLATFORM）"
while read -r img; do
  [ -z "$img" ] && continue
  echo "    pull $img"
  docker pull --platform "$PLATFORM" "$img"
done < "$OUT/images.txt"

echo "==> 导出 $OUT/images.tar"
docker save -o "$OUT/images.tar" $(tr '\n' ' ' < "$OUT/images.txt")

echo ""
echo "完成。产物："
ls -lh "$OUT/images.txt" "$OUT/images.tar"
echo ""
echo "下一步：把 $OUT/images.tar 与 $OUT/images.txt 一起搬到内网，"
echo "        执行 13-import-to-harbor.sh images.txt"
