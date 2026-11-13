#!/usr/bin/env bash
# ============================================================
# HiMarket 部署前自检（只读，不改集群、不装东西）
#
# 在集群操作机上执行：把 12 项前置条件全查一遍，输出 PASS/FAIL 表格。
# 全 PASS 再跑 ./install.sh，能避免装到一半才回滚。
#
# 用法：
#   chmod +x 15-preflight-check.sh
#   ./15-preflight-check.sh
#
# 可覆盖：
#   BASE=/var/lib/paascontainer/himarket
#   NS=himarket
#   HARBOR=harbor.example.internal
# ============================================================
BASE=${BASE:-/var/lib/paascontainer/himarket}
NS=${NS:-himarket}
HARBOR=${HARBOR:-harbor.example.internal}
HUB=$HARBOR/ai-platform/himarket
HCHART=$BASE/charts/higress
HIMARKET_SRC=$BASE/himarket-0.8.2/deploy/helm

pass=0; fail=0
ok()   { printf "  \033[32m[PASS]\033[0m %s\n" "$*"; pass=$((pass+1)); }
bad()  { printf "  \033[31m[FAIL]\033[0m %s\n" "$*"; fail=$((fail+1)); }
warn() { printf "  \033[33m[WARN]\033[0m %s\n" "$*"; }
sec()  { printf "\n\033[1m%s\033[0m\n" "$*"; }

sec "一、文件与工具"
[ -f "$HIMARKET_SRC/install.sh" ]                    && ok "install.sh 存在"        || bad "找不到 $HIMARKET_SRC/install.sh"
[ -f "$HIMARKET_SRC/himarket/values.yaml" ]          && ok "himarket values 存在"   || bad "缺少 himarket/values.yaml"
[ -f "$HCHART/Chart.yaml" ]                          && ok "higress chart 存在"     || bad "找不到 $HCHART/Chart.yaml"
[ -d "$HCHART/charts/higress-core" ]                 && ok "higress-core 子 chart"  || bad "缺 higress-core"
[ -d "$HCHART/charts/higress-console" ]              && ok "higress-console 子 chart" || bad "缺 higress-console"
command -v helm  >/dev/null && ok "helm $(helm version --short 2>/dev/null)" || bad "helm 缺失"
command -v jq    >/dev/null && ok "jq 存在"    || bad "jq 缺失（install.sh 需要）"
command -v python3 >/dev/null && ok "python3 存在" || bad "python3 缺失（install.sh 需要）"
bash -n "$HIMARKET_SRC/install.sh" 2>/dev/null       && ok "install.sh 语法正确"     || bad "install.sh 语法错误"

sec "二、install.sh 是否已改成内网"
grep -q "HIMARKET_HUB:-\?$HUB" "$HIMARKET_SRC/install.sh" \
  && ok "HIMARKET_HUB = $HUB" || bad "HIMARKET_HUB 未指向 Harbor"
grep -q "NACOS_IMAGE_REGISTRY:-\?$HARBOR" "$HIMARKET_SRC/install.sh" \
  && ok "NACOS_IMAGE_REGISTRY = $HARBOR" || bad "NACOS registry 未改"
grep -q '"latest"' "$HIMARKET_SRC/install.sh" \
  && warn "install.sh 里还有 \"latest\"（确认是否只是无关文案）" || ok "无 latest 残留"
grep -q '^\s*helm repo add' "$HIMARKET_SRC/install.sh" \
  && bad "helm repo add 未禁用（离线会卡住）" || ok "helm repo 操作已禁用"
grep -q 'HIGRESS_CHART_REF:-$HCHART' "$HIMARKET_SRC/install.sh" \
  && ok "HIGRESS_CHART_REF 指向本地 chart" || warn "HIGRESS_CHART_REF 默认值可能不是 $HCHART（会去连公网）"
grep -q -- '--set "service.type=ClusterIP"' "$HIMARKET_SRC/install.sh" \
  && ok "nacos Service 已固定 ClusterIP（不会额外建 LB）" || bad "nacos 未固定 ClusterIP，会把配置中心暴露到 LB"

sec "三、chart 值是否指向 Harbor"
grep -q "$HARBOR" "$HIMARKET_SRC/himarket/values.yaml" \
  && ok "himarket values 含 Harbor 地址" || warn "himarket values 未含 Harbor（脚本 --set 会覆盖，通常无碍）"
grep -A6 '^sandbox:' "$HIMARKET_SRC/himarket/values.yaml" | grep -q 'tag:.*v0\.8\.2' \
  && ok "sandbox.image.tag = v0.8.2" || bad "sandbox tag 不是 v0.8.2（脚本不传，Harbor 没 :latest 会拉不到）"
grep -q "hub: $HARBOR/ai-platform" "$HCHART/charts/higress-core/values.yaml" \
  && ok "higress-core hub 已改" || bad "higress-core hub 未改"
grep -rq 'higress-registry.cn-hangzhou' "$HCHART/charts/higress-console/values.yaml" 2>/dev/null \
  && bad "higress-console 仍指向阿里云" || ok "higress-console 无公网残留"

sec "四、集群资源"
kubectl get ns "$NS" >/dev/null 2>&1 && ok "namespace $NS 存在" || bad "namespace $NS 不存在"
kubectl -n "$NS" get secret harbor-secret >/dev/null 2>&1 \
  && ok "secret harbor-secret 存在" || bad "secret harbor-secret 不存在"
kubectl -n "$NS" get sa default -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null | grep -q harbor-secret \
  && ok "default SA 已挂 imagePullSecret" || warn "default SA 未挂 secret（若 chart 自带 imagePullSecrets 可忽略）"

avail=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="local-storage")]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Available)
[ "${avail:-0}" -ge 2 ] && ok "local-storage 类 PV 有 $avail 个 Available（需 2 个）" \
  || bad "local-storage 类 PV 只有 ${avail:-0} 个 Available，需要 2 个"

sec "五、env 配置"
ENVF=~/himarket-install.env
ST=LoadBalancer
if [ -f "$ENVF" ]; then
  for k in SERVICE_TYPE MYSQL_STORAGE_CLASS SANDBOX_STORAGE_CLASS; do
    v=$(grep -E "^$k=" "$ENVF" | tail -1 | cut -d= -f2)
    case "$k" in
      SERVICE_TYPE)
        case "$v" in
          LoadBalancer|NodePort|ClusterIP) ok "$k=$v" ;;
          *) bad "$k=$v（应为 LoadBalancer / NodePort / ClusterIP）" ;;
        esac
        [ -n "$v" ] && ST=$v ;;
      *) [ "$v" = "local-storage" ] && ok "$k=$v" || bad "$k=$v（应为 local-storage）" ;;
    esac
  done
else
  bad "$ENVF 不存在"
fi
[ "$ST" = "LoadBalancer" ] && warn "SERVICE_TYPE=LoadBalancer：KCS 会为 admin/frontend/console 各建一个云负载均衡实例（计费 + 公网 IP）"

sec "六、渲染核对（不接触集群）"
cd "$HIMARKET_SRC" || exit 1
render_h=$(helm template himarket ./himarket -n "$NS" \
  --set hub="$HUB" --set size=small \
  --set frontend.image.tag=v0.8.2 --set admin.image.tag=v0.8.2 --set server.image.tag=v0.8.2 \
  --set mysql.image.tag=8.0.32 \
  --set frontend.service.type="$ST" --set admin.service.type="$ST" \
  --set mysql.persistence.storageClass=local-storage \
  --set sandbox.persistence.storageClass=local-storage 2>/dev/null) || bad "himarket 渲染失败"

if [ -n "${render_h:-}" ]; then
  echo "$render_h" | grep -q "sandbox:v0.8.2" && ok "渲染：sandbox 使用 v0.8.2" || bad "渲染：sandbox tag 异常"
  echo "$render_h" | grep -q 'storageClassName: "local-storage"' && ok "渲染：PVC 用 local-storage" || bad "渲染：PVC storageClass 异常"
  echo "$render_h" | grep -q 'image:.*aliyuncs' && bad "渲染：仍有阿里云镜像" || ok "渲染：无阿里云镜像"
fi

render_g=$(helm template higress "$HCHART" -n "$NS" \
  --set higress-core.global.enableRedis=true --set higress-core.gateway.replicas=1 \
  --set higress-console.service.type=NodePort 2>/dev/null) || bad "higress 渲染失败"
if [ -n "${render_g:-}" ]; then
  echo "$render_g" | grep -q 'image:.*higress-registry' && bad "渲染：higress 仍有公网镜像" || ok "渲染：higress 镜像全部内网"
  echo "$render_g" | grep -q "redis-stack-server" && ok "渲染：redis-stack-server 已包含" || warn "渲染：未见 redis（确认 enableRedis 是否生效）"
fi

sec "结果"
printf "  PASS: %d    FAIL: %d\n" "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  printf "\n  \033[32m全部通过，可以执行：\033[0m\n"
  printf "  cd %s && ./install.sh\n\n" "$HIMARKET_SRC"
else
  printf "\n  \033[31m有 %d 项未通过，先修完再部署。\033[0m\n\n" "$fail"
fi
