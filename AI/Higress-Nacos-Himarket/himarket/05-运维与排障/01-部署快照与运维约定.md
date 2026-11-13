# HiMarket 部署完成记录与运维手册

> 环境：移动云 KCS，K8s v1.29.5-eki.4.1.0，3 master + 3 worker（containerd）
> 版本：HiMarket v0.8.2 / Nacos v3.2.1 / Higress chart 2.2.5
> 命名空间：`himarket`（全部组件同 ns）
> 部署日期：2026-10-27

---

## 一、最终架构

```
用户 → CLB(elb_ai_platform_dev) <MODEL_GW_IP>:30080/30443
        → higress-gateway (LoadBalancer, 3 副本, Service 端口 30080/30443)
            → Ingress(按 Host 分流, ingressClass=himarket)
                ├─ himarket-admin.example.internal    → himarket-admin   (ClusterIP:80)
                ├─ himarket.example.internal          → himarket-frontend(ClusterIP:80)
                └─ /api                      → himarket-server  (ClusterIP:80)
```

其余组件全部 ClusterIP：`nacos`、`higress-console`、`higress-controller`、`redis-stack-server`、`sandbox-shared`、`mysql-headless-svc`。

**唯一对外入口是 Higress 网关**，符合"只暴露网关、业务统一走路由"的架构要求。

---

## 二、组件与资源清单

| 组件 | 副本 | 端口 | 存储 |
|---|---|---|---|
| himarket-server | 1 | 8080 | — |
| himarket-admin / frontend | 各 1 | 8000（Service 80） | — |
| sandbox-shared | 1 | 8080 | PVC 50Gi |
| mysql | 1 (STS) | 3306 | PVC 50Gi |
| nacos | 1 | 8080/8848/9848 | 复用 mysql |
| higress-gateway | **3** | 30080/30443 | — |
| higress-controller | 1 (2 容器) | 8888 | — |
| higress-console | 1 | 8080 | — |
| redis-stack-server | 1 | 6379 | — |

镜像全部来自私有 Harbor：`http://harbor.example.internal/ai-platform/{himarket,nacos,higress}/*`

存储：集群只有 `local-storage`（no-provisioner），手工创建 2 个静态 PV（hostPath）：
- `/var/lib/paascontainer/himarket/mysql`
- `/var/lib/paascontainer/himarket/sandbox`
- nodeAffinity 钉在 worker `<HIMARKET_NODE_WORKER2>`

> ⚠️ 实际绑定发生了交叉：`mysql-data-mysql-0` → `himarket-sandbox-pv`，`sandbox-workspace-pvc` → `himarket-mysql-pv`。
> 即 **MySQL 真实数据在 `/var/lib/paascontainer/himarket/sandbox` 目录**，沙箱数据在 `.../mysql` 目录。功能无影响，备份/排障时注意别搞反。

---

## 三、日常运维约定（**必须遵守**）

### 1. 禁止全量执行 `./install.sh`

脚本里的 `helm upgrade --install` 带 `--wait --atomic`，会等待网关 Service 拿到 `EXTERNAL-IP`。当前网关 Service 因共享 CLB 监听器归属问题长期处于 `pending`，全量执行必然 900 秒超时并回滚整个 higress release。

### 2. 升级 higress 用不带 `--wait` 的命令

```bash
cd /var/lib/paascontainer/himarket/himarket-0.8.2/deploy/helm
HIGRESS_PWD=$(grep '^HIGRESS_PASSWORD=' ~/himarket-install.env | cut -d= -f2)
helm upgrade --install higress /var/lib/paascontainer/himarket/charts/higress \
  -n himarket \
  --set higress-core.global.enableRedis=true \
  --set higress-core.global.ingressClass=himarket \
  --set higress-console.global.ingressClass=himarket \
  --set higress-console.service.type=ClusterIP \
  --set higress-console.admin.username=admin \
  --set "higress-console.admin.password=${HIGRESS_PWD}" \
  --set higress-core.gateway.replicas=3
```

### 3. 重装后必须补 ServiceAccount 的 imagePullSecret

chart 使用的是独立 SA（`himarket` / `higress-gateway` / `higress-console` / `higress-controller`），helm 回滚或卸载会连带删除它们，重装后必须重新 patch，否则 `ImagePullBackOff`：

```bash
for sa in himarket default higress-gateway higress-console higress-controller; do
  kubectl patch sa "$sa" -n himarket --type merge \
    -p '{"imagePullSecrets":[{"name":"harbor-secret"}]}' 2>/dev/null
done
```

> `imagePullSecrets` 在 Pod 创建时固化，patch 完 SA 必须删 Pod 重建才生效。

### 4. 节点扩缩容要手工维护 CLB 后端池

因为监听器是手工创建的，CCM 不托管，新增 worker 后需要到 CLB 上把新节点的 `30080` / `30443` 加入后端服务器组。

### 5. 不要在网关 Service 不存在时执行 helm 命令

避免 `another operation (install/upgrade/rollback) is in progress`：先 `helm list -n himarket --all` 看状态，`pending-*` 时先 `helm uninstall higress -n himarket`。

---

## 四、后续优化项（建议择机执行）

**把手建监听器删掉，改由 CCM 托管**：

1. 删除 CLB 上的 `Listener_himarket_poc30080` / `Listener_himarket_poc30443`
2. 触发 reconcile：`kubectl annotate svc higress-gateway -n himarket --overwrite higress.io/reconcile="$(date +%s)"`
3. 网关 Service 会正常拿到 `EXTERNAL-IP`

收益：Service 状态正确、`--wait` 可用、后端池自动维护。代价：删监听器时有秒级中断。

---

## 五、初始化钩子的坑与解法

`hooks/post_ready.d/` 里 5 个钩子都从操作机本地执行，且**只认 Service 的 LoadBalancer IP，取不到就回退 `*.svc.cluster.local`**。因为业务 Service 全是 ClusterIP，从节点上直接跑必然 `HTTP 000`。

临时解法（不改钩子、不改集群配置）：

```bash
cat >> /etc/hosts <<'EOF'
127.0.0.2 himarket-admin.himarket.svc.cluster.local
127.0.0.3 himarket-frontend.himarket.svc.cluster.local
127.0.0.4 nacos.himarket.svc.cluster.local
EOF

kubectl -n himarket port-forward --address 127.0.0.2 svc/himarket-admin    80:80   >/tmp/pf-admin.log 2>&1 &
kubectl -n himarket port-forward --address 127.0.0.3 svc/himarket-frontend 80:80   >/tmp/pf-front.log 2>&1 &
kubectl -n himarket port-forward --address 127.0.0.4 svc/nacos            8080:8080 >/tmp/pf-nacos.log 2>&1 &

cd /var/lib/paascontainer/himarket/himarket-0.8.2/deploy/helm
./install.sh --init-data

pkill -f 'kubectl.*port-forward'
sed -i '/svc.cluster.local/d' /etc/hosts
```

---

## 六、排障速查

| 现象 | 定位命令 | 常见原因 |
|---|---|---|
| Pod `ImagePullBackOff` | `kubectl describe pod -n himarket <pod>` | SA 没挂 harbor-secret |
| PVC `Pending` | `kubectl get pv;pvc -n himarket` | 静态 PV 未建 / nodeAffinity 节点不可调度 |
| 网关 `EXTERNAL-IP <pending>` | `kubectl describe svc higress-gateway -n himarket` | CLB 监听器端口冲突 / 审批未完成 |
| helm 报 operation in progress | `helm list -n himarket --all` | 上一个操作残留 pending 锁 |
| 页面 200 但登录失败 | F12 Network 看 API 路径 | 缺 `/api` 的 Ingress 路由 |
| 域名访问 404 | `kubectl get ingress -n himarket` | 缺 Host 路由，落到了 `default` 兜底 |

关键日志位置：
- 部署：`/root/himarket-install.log`
- CCM：`kubectl -n kube-system logs -l app=ecloud-controller-manager --tail=100`
- 应用：`kubectl logs -n himarket deploy/himarket-server`

---

## 七、账号与配置

配置文件：`~/himarket-install.env`（含全部密码，git 不可提交）

```bash
grep -E 'ADMIN_PASSWORD|FRONT_PASSWORD|MYSQL_ROOT_PASSWORD|NACOS_ADMIN_PASSWORD|HIGRESS_PASSWORD' ~/himarket-install.env
```

| 入口 | 用户名 | 地址 |
|---|---|---|
| 管理后台 | admin | `http://himarket-admin.example.internal:30080` |
| 开发者门户 | user | `http://himarket.example.internal:30080` |
| Higress 控制台 | admin | 内部 ClusterIP，需 port-forward 8080 |
| Nacos 控制台 | nacos | 内部 ClusterIP，需 port-forward 8080 |

客户端 hosts（内网未做 DNS 时）：

```
<MODEL_GW_IP>  himarket-admin.example.internal  himarket.example.internal
```
