#!/usr/bin/env bash
# ============================================================
# HiMarket 内网部署准备（在集群操作机上执行，只改配置，不部署）
#
# 做的事：
#   1. 校验 5 个离线文件 → 解包 → 装 helm
#   2. 改 install.sh 里写死的公网 registry（第 818-820 行那三个默认值）
#   3. 改镜像 tag 默认值（v0.8.2 / 8.0.32 / nacos 版本）
#   4. 注释掉 add_repos 里的 helm repo add / update（离线必做）
#   5. 改 higress chart 的 global.hub 指向 Harbor
#   6. 生成 ~/himarket-install.env（storageClass / NodePort / size）
#   7. 自检：渲染一遍，确认所有镜像都指向 Harbor
#
# 用法：
#   chmod +x prepare-internal.sh
#   ./prepare-internal.sh
#
# 可覆盖：
#   HARBOR=harbor.example.internal/ai-platform
#   NAMESPACE=himarket
#   STORAGE_CLASS=local-storage
#   SIZE=small            # small / standard / large
#   HARBOR_HIMARKET=harbor.example.internal/ai-platform/himarket
# ============================================================
set -euo pipefail

HARBOR=${HARBOR:-harbor.example.internal/ai-platform}
HARBOR_HIMARKET=${HARBOR_HIMARKET:-$HARBOR/himarket}
NAMESPACE=${NAMESPACE:-himarket}
STORAGE_CLASS=${STORAGE_CLASS:-local-storage}
SIZE=${SIZE:-small}
TAG=${TAG:-v0.8.2}
MYSQL_TAG=${MYSQL_TAG:-8.0.32}
NACOS_TAG=${NACOS_TAG:-v3.2.1-2026.03.30}
WORKDIR=${WORKDIR:-/opt/himarket}
CHART_PARENT=${CHART_PARENT:-/opt/charts}

say() { printf "\n\033[1m==> %s\033[0m\n" "$*"; }
warn() { printf "\033[33m!! %s\033[0m\n" "$*"; }

cd "$WORKDIR" 2>/dev/null || { echo "找不到 $WORKDIR"; exit 1; }

# ---------- 1. 校验 + 解包 ----------
say "1/7 校验离线文件"
REQUIRED=(v0.8.2.tar.gz helm-v3.22.1-linux-amd64.tar.gz)
missing=0
for f in "${REQUIRED[@]}"; do
  if [ -f "$f" ]; then echo "   ok  $f"; else echo "   缺失 $f"; missing=1; fi
done
[ "$missing" = "0" ] || { echo "先补齐文件再跑"; exit 1; }

say "解包源码与 helm"
[ -d himarket-0.8.2 ] || tar xzf v0.8.2.tar.gz
tar xzf helm-v3.22.1-linux-amd64.tar.gz
install -m 0755 linux-amd64/helm /usr/local/bin/helm
helm version --short

say "解包 higress chart 到 $CHART_PARENT"
mkdir -p "$CHART_PARENT"
[ -d "$CHART_PARENT/higress" ] || tar xzf charts/higress-2.2.5.tgz -C "$CHART_PARENT"
ls -1 "$CHART_PARENT/higress/charts/" | sed 's/^/   /'

# ---------- 2~4. 改 install.sh ----------
S=himarket-0.8.2/deploy/helm/install.sh
[ -f "$S" ] || { echo "找不到 $S"; exit 1; }
say "2/7 备份并修改 install.sh"
[ -f "$S.orig" ] || cp "$S" "$S.orig"

python3 - "$S" "$HARBOR_HIMARKET" "$HARBOR" "$TAG" "$MYSQL_TAG" "$NACOS_TAG" <<'PY'
import re, sys
path, hub_himarket, harbor, tag, mysql_tag, nacos_tag = sys.argv[1:7]
src = open(path).read()
orig = src

def sub_default(text, var, value):
    """把 VAR="${VAR:-旧默认值}" 里的旧默认值换成 value"""
    pattern = r'^(\s*' + var + r'="\$\{' + var + r':-[^}]*\}")'
    def repl(m):
        return re.sub(r':-[^}]*\}', ':-' + value + '}', m.group(1))
    text2, n = re.subn(pattern, repl, text, flags=re.M)
    if n == 0:
        print(f"   !! 未找到 {var} 的默认值写法，请手工改")
    else:
        print(f"   ok  {var} -> {value}")
    return text2

src = sub_default(src, 'HIMARKET_HUB', hub_himarket)
src = sub_default(src, 'NACOS_IMAGE_REGISTRY', harbor)
src = sub_default(src, 'NACOS_IMAGE_REPOSITORY', 'ai-platform/nacos/nacos-server')
src = sub_default(src, 'HIMARKET_IMAGE_TAG', tag)
src = sub_default(src, 'HIMARKET_MYSQL_IMAGE_TAG', mysql_tag)
src = sub_default(src, 'NACOS_VERSION', nacos_tag)

# 注释掉联网的 repo 操作
lines = src.split('\n')
out = []
commented = 0
for ln in lines:
    st = ln.strip()
    if st.startswith('helm repo add') or st.startswith('helm repo update'):
        out.append('    # [offline] ' + st)
        commented += 1
    else:
        out.append(ln)
src = '\n'.join(out)
print(f"   注释掉 {commented} 行 helm repo 操作")

if src != orig:
    open(path, 'w').write(src)
    print("   install.sh 已更新")
else:
    print("   install.sh 无变化")
PY

say "3/7 校验改后的关键行"
grep -n 'HIMARKET_HUB=\|NACOS_IMAGE_REGISTRY=\|NACOS_IMAGE_REPOSITORY=\|HIMARKET_IMAGE_TAG=\|HIMARKET_MYSQL_IMAGE_TAG=\|NACOS_VERSION=' "$S" | sed 's/^/   /'

# ---------- 5. 改 higress hub ----------
say "4/7 改 higress chart 的镜像仓库"
for v in "$CHART_PARENT/higress/charts/higress-core/values.yaml" "$CHART_PARENT/higress/values.yaml"; do
  [ -f "$v" ] || continue
  cp -n "$v" "$v.orig" 2>/dev/null || true
  sed -i 's#higress-registry\.cn-hangzhou\.cr\.aliyuncs\.com#'"$HARBOR"'#g' "$v"
  echo "   ok  $v"
done

# ---------- 6. env ----------
say "5/7 生成 ~/himarket-install.env"
ENVF=~/himarket-install.env
[ -f "$ENVF" ] || cp himarket-0.8.2/deploy/helm/.env.example "$ENVF" 2>/dev/null || : > "$ENVF"

set_env() {
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENVF"; then
    sed -i "s#^${k}=.*#${k}=${v}#" "$ENVF"
  else
    echo "${k}=${v}" >> "$ENVF"
  fi
}
set_env NAMESPACE            "$NAMESPACE"
set_env MYSQL_STORAGE_CLASS  "$STORAGE_CLASS"
set_env SANDBOX_STORAGE_CLASS "$STORAGE_CLASS"
set_env MYSQL_STORAGE_SIZE   50Gi
set_env SANDBOX_STORAGE_SIZE 50Gi
set_env HIMARKET_SIZE        "$SIZE"
set_env HIGRESS_INGRESS_CLASS "$NAMESPACE"
set_env SKIP_AI_MODEL_INIT   true
# 服务类型：脚本用 ${SERVICE_TYPE}，缺省可能是 LoadBalancer
set_env SERVICE_TYPE         NodePort

grep -E "NAMESPACE|STORAGE_CLASS|STORAGE_SIZE|HIMARKET_SIZE|INGRESS_CLASS|SKIP_AI|SERVICE_TYPE" "$ENVF" | sed 's/^/   /'

# ---------- 7. 自检 ----------
say "6/7 渲染自检（镜像必须全部指向 $HARBOR）"
H=himarket-0.8.2/deploy/helm
helm template himarket "$H/himarket" -n "$NAMESPACE" >/dev/null 2>&1 && echo "   himarket chart 渲染 OK" || warn "himarket chart 渲染失败"
helm template nacos "$H/nacos" -n "$NAMESPACE" >/dev/null 2>&1 && echo "   nacos chart 渲染 OK" || warn "nacos chart 渲染失败"
helm template higress "$CHART_PARENT/higress" -n "$NAMESPACE" >/dev/null 2>&1 && echo "   higress chart 渲染 OK" || warn "higress chart 渲染失败"

say "7/7 检查残留的公网 registry"
if grep -rl 'aliyuncs.com' "$H/himarket/values.yaml" "$H/nacos/values.yaml" \
     "$CHART_PARENT/higress/values.yaml" "$CHART_PARENT/higress/charts/higress-core/values.yaml" 2>/dev/null; then
  warn "上面这些值文件里还有 aliyuncs.com，虽然会被 --set 覆盖或已改，仍建议确认"
else
  echo "   OK 未发现残留"
fi

cat <<EOF

================ 准备完成 ================
下一步（确认无误后执行）：

  kubectl apply -f local-storage-pv.yaml      # 记得先改里面的节点名
  kubectl get pv                              # 两个都要 Available

  export HIGRESS_CHART_REF=$CHART_PARENT/higress
  cd $WORKDIR/himarket-0.8.2/deploy/helm
  ./install.sh

部署后验证：
  kubectl get pvc -n $NAMESPACE          # 必须 Bound
  kubectl get pods -n $NAMESPACE -w
  kubectl get svc  -n $NAMESPACE
==========================================
EOF
