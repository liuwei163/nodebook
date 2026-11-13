#!/usr/bin/env bash
# ============================================================
# HiMarket 离线物料一键打包 —— 摆渡机（有外网）执行
#
# 产出 himarket-offline-<版本>/ 目录 + 同名 tar 包，内含：
#   源码包 / helm 二进制 / higress chart（含子 chart）/ 镜像清单 / images.tar / MANIFEST / SHA256
#
# 用法：
#   chmod +x 11-fetch-offline-bundle.sh
#   ./11-fetch-offline-bundle.sh
#
# 可覆盖变量（默认值与本项目「01-物料清单.md」一致）：
#   HIMARKET_VERSION=v0.8.2        HiMarket 版本（前一版 v0.8.1）
#   HELM_VERSION=v3.22.1           helm 版本，建议锁 3.x
#   HIGRESS_CHART_VERSION=2.2.5    higress chart 版本
#   PLATFORM=linux/amd64           目标架构
#   WORKDIR=$PWD                  工作目录
# ============================================================
set -euo pipefail

HIMARKET_VERSION=${HIMARKET_VERSION:-v0.8.2}
HELM_VERSION=${HELM_VERSION:-v3.22.1}
HIGRESS_CHART_VERSION=${HIGRESS_CHART_VERSION:-2.2.5}
PLATFORM=${PLATFORM:-linux/amd64}
WORKDIR=${WORKDIR:-$PWD}

APP_VER=${HIMARKET_VERSION#v}                 # v0.8.2 -> 0.8.2
BUNDLE="$WORKDIR/himarket-offline-$HIMARKET_VERSION"

for c in curl tar gzip; do
  command -v "$c" >/dev/null || { echo "缺少 $c"; exit 1; }
done

mkdir -p "$BUNDLE/charts"
cd "$BUNDLE"

echo "==============================================="
echo " HiMarket 离线打包"
echo "   应用版本   : $HIMARKET_VERSION"
echo "   helm       : $HELM_VERSION"
echo "   higress    : $HIGRESS_CHART_VERSION"
echo "   目标架构   : $PLATFORM"
echo "   输出目录   : $BUNDLE"
echo "==============================================="

# ---------- 1. 源码包 ----------
echo ""
echo "==> [1/6] 下载 HiMarket 源码包"
SRC_TGZ="himarket-$APP_VER.tar.gz"
[ -f "$SRC_TGZ" ] || curl -fL --retry 3 \
  -o "$SRC_TGZ" \
  "https://github.com/higress-group/himarket/archive/refs/tags/$HIMARKET_VERSION.tar.gz"
ls -lh "$SRC_TGZ"
tar xzf "$SRC_TGZ"        # 得到 himarket-$APP_VER/

CHART_ROOT="$BUNDLE/himarket-$APP_VER/deploy/helm"
[ -f "$CHART_ROOT/himarket/Chart.yaml" ] || { echo "源码包内找不到 himarket chart"; exit 1; }
[ -f "$CHART_ROOT/nacos/Chart.yaml" ]    || { echo "源码包内找不到 nacos chart";    exit 1; }

# ---------- 2. helm 二进制 ----------
echo ""
echo "==> [2/6] 下载 helm $HELM_VERSION"
HELM_TGZ="helm-$HELM_VERSION-linux-amd64.tar.gz"
[ -f "$HELM_TGZ" ] || curl -fL --retry 3 -o "$HELM_TGZ" "https://get.helm.sh/$HELM_TGZ"
ls -lh "$HELM_TGZ"

# 本地临时解一份 helm 用来渲染（不装到系统）
tar xzf "$HELM_TGZ"
HELM_BIN="$BUNDLE/linux-amd64/helm"
export PATH="$BUNDLE/linux-amd64:$PATH"
"$HELM_BIN" version --short

# ---------- 3. higress chart + 子 chart 校验 ----------
echo ""
echo "==> [3/6] 拉取 higress chart $HIGRESS_CHART_VERSION"
REPO_URL="https://higress.io/helm-charts/"
"$HELM_BIN" repo add higress.io "$REPO_URL" --force-update >/dev/null
"$HELM_BIN" repo update >/dev/null
"$HELM_BIN" pull higress --repo "$REPO_URL" --version "$HIGRESS_CHART_VERSION" \
  --untar --untardir "$BUNDLE/charts"

SUB_DIR="$BUNDLE/charts/higress/charts"
mkdir -p "$SUB_DIR"
echo "    子 chart 检查："
ls -1 "$SUB_DIR" 2>/dev/null | sed 's/^/      /' || true

if ! ls "$SUB_DIR"/higress-console-*.tgz >/dev/null 2>&1; then
  echo "    !! 缺少 higress-console 子 chart，单独拉取"
  "$HELM_BIN" pull higress-console --repo "$REPO_URL" --version "$HIGRESS_CHART_VERSION" \
    --untar --untardir "$SUB_DIR" || echo "    !! higress-console 拉取失败，请手工补齐"
fi

if ! ls "$SUB_DIR"/higress-core-*.tgz >/dev/null 2>&1; then
  echo "    !! 缺少 higress-core 子 chart（file:// 依赖，必须从源码取）"
  echo "       正在下载 higress 源码包作为兜底素材"
  HSRC="higress-$HIGRESS_CHART_VERSION.tar.gz"
  [ -f "$HSRC" ] || curl -fL --retry 3 -o "$HSRC" \
    "https://github.com/higress-group/higress/archive/refs/tags/v$HIGRESS_CHART_VERSION.tar.gz" || true
fi

# ---------- 4. 渲染镜像清单 ----------
echo ""
echo "==> [4/6] 渲染 chart，提取镜像清单"
RENDER="$BUNDLE/.render"
mkdir -p "$RENDER"

"$HELM_BIN" template himarket "$CHART_ROOT/himarket" -n himarket \
  --set frontend.image.tag="$HIMARKET_VERSION" \
  --set admin.image.tag="$HIMARKET_VERSION" \
  --set server.image.tag="$HIMARKET_VERSION" \
  --set sandbox.image.tag="$HIMARKET_VERSION" > "$RENDER/himarket.yaml" \
  || echo "    !! himarket 渲染失败"

"$HELM_BIN" template nacos "$CHART_ROOT/nacos" -n himarket > "$RENDER/nacos.yaml" 2>/dev/null \
  || echo "    !! nacos 渲染失败（可能缺 database.host 等必填项，用兜底镜像补齐）"

"$HELM_BIN" template higress "$BUNDLE/charts/higress" -n higress-system > "$RENDER/higress.yaml" 2>/dev/null \
  || echo "    !! higress 渲染失败（检查 charts/higress/charts 子 chart 是否齐全）"

IMAGES_FILE="$BUNDLE/images.txt"
grep -hoE 'image:[[:space:]]*"?[^"[:space:]]+' "$RENDER"/*.yaml 2>/dev/null \
  | sed -E 's/image:[[:space:]]*"?//' \
  | grep -v '{{' | grep -vE '^(none|null|\$)' \
  | sort -u > "$IMAGES_FILE" || true

# 兜底：渲染不全时补上已知镜像，避免搬漏
FALLBACK="$BUNDLE/.fallback.txt"
cat > "$FALLBACK" <<EOF
opensource-registry.cn-hangzhou.cr.aliyuncs.com/higress-group/himarket-server:$HIMARKET_VERSION
opensource-registry.cn-hangzhou.cr.aliyuncs.com/higress-group/himarket-admin:$HIMARKET_VERSION
opensource-registry.cn-hangzhou.cr.aliyuncs.com/higress-group/himarket-frontend:$HIMARKET_VERSION
opensource-registry.cn-hangzhou.cr.aliyuncs.com/higress-group/sandbox:$HIMARKET_VERSION
nacos-registry.cn-hangzhou.cr.aliyuncs.com/nacos/nacos-server:v3.2.1-2026.03.30
higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/redis-stack-server:7.4.0-v3
EOF

COUNT=$(wc -l < "$IMAGES_FILE" | tr -d ' ')
if [ "$COUNT" -lt 10 ]; then
  echo "    渲染结果只有 $COUNT 个，补入兜底清单（事后请人工核对）"
  cat "$FALLBACK" >> "$IMAGES_FILE"
  sort -u "$IMAGES_FILE" -o "$IMAGES_FILE"
fi

echo ""
echo "    最终镜像清单（$(wc -l < "$IMAGES_FILE" | tr -d ' ') 个）："
sed 's/^/      /' "$IMAGES_FILE"

echo ""
echo "    !! 请人工核对下面两项，缺失会导致内网部署失败："
echo "       - higress-group/mysql 的实际 tag（chart 默认 latest）"
echo "       - 4 个 higress 镜像（gateway/pilot/controller/console）是否齐全"

# ---------- 5. 拉取并导出 ----------
echo ""
echo "==> [5/6] 拉取镜像（$PLATFORM），这一步最慢"
if command -v docker >/dev/null 2>&1; then
  CONTAINER_CLI=docker
elif command -v nerdctl >/dev/null 2>&1; then
  CONTAINER_CLI=nerdctl
else
  echo "缺少 docker / nerdctl，无法拉取镜像"; exit 1
fi

while read -r img; do
  [ -z "$img" ] && continue
  echo "    pull $img"
  $CONTAINER_CLI pull --platform "$PLATFORM" "$img"
done < "$IMAGES_FILE"

echo "    save images.tar"
$CONTAINER_CLI save -o "$BUNDLE/images.tar" $(tr '\n' ' ' < "$IMAGES_FILE")
ls -lh "$BUNDLE/images.tar"

# ---------- 6. MANIFEST + 校验 + 打包 ----------
echo ""
echo "==> [6/6] 生成 MANIFEST 与校验和"
{
  echo "# HiMarket 离线物料 MANIFEST"
  echo "bundle_version=$HIMARKET_VERSION"
  echo "higress_chart_version=$HIGRESS_CHART_VERSION"
  echo "helm_version=$HELM_VERSION"
  echo "platform=$PLATFORM"
  echo "built_at=$(date -Iseconds)"
  echo ""
  echo "## files"
  echo "$SRC_TGZ"
  echo "$HELM_TGZ"
  echo "charts/higress/"
  echo "images.txt"
  echo "images.tar"
  echo ""
  echo "## images"
  cat "$IMAGES_FILE"
} > "$BUNDLE/MANIFEST.txt"

cd "$BUNDLE"
rm -rf .render .fallback.txt
find . -maxdepth 1 -type f ! -name SHA256SUMS -exec sha256sum {} \; > SHA256SUMS
sha256sum charts/higress-*.tgz >> SHA256SUMS 2>/dev/null || true

cd "$WORKDIR"
tar czf "himarket-offline-$HIMARKET_VERSION.tar.gz" "himarket-offline-$HIMARKET_VERSION"

echo ""
echo "==============================================="
echo " 完成"
echo "   目录 : $BUNDLE"
echo "   打包 : $WORKDIR/himarket-offline-$HIMARKET_VERSION.tar.gz"
ls -lh "$WORKDIR/himarket-offline-$HIMARKET_VERSION.tar.gz"
echo ""
echo " 下一步（内网）："
echo "   tar xzf himarket-offline-$HIMARKET_VERSION.tar.gz"
echo "   install -m 0755 linux-amd64/helm /usr/local/bin/helm"
echo "   docker load -i himarket-offline-$HIMARKET_VERSION/images.tar"
echo "   HARBOR=harbor.example.internal ./13-import-to-harbor.sh images.txt"
echo "==============================================="
