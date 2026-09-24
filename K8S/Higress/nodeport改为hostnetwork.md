可以，端口保持 30080/30443 反而更简单——ELB 侧**完全不用动**，健康检查、后端端口、监听器全部维持原状。核心改动只有一个：让 envoy 直接在节点的 30080/30443 上监听(hostNetwork),svc 变 ClusterIP,原来 NodePort 那条转发路径消失，但对外表现完全一样。

## 完整流程

### 第 0 步：前置检查

```bash
# 3 台入口节点上分别确认 30080/30443 没被其他进程占用
ss -lntp | grep -E ':30080 |:30443 '
```

### 第 1 步：节点打标签(已做过就跳过)

```bash
kubectl label node 192.168.59.21 higress-ingress=true
kubectl label node 192.168.79.51 higress-ingress=true
kubectl label node 192.168.127.44 higress-ingress=true
```

### 第 2 步：改 values 并升级

`higress-values.yaml` 的 gateway 部分:

```yaml
higress-core:
  gateway:
    ports:                     # 容器端口改成 30080/30443,envoy 就绑这两个
    - name: http2
      port: 30080
      targetPort: 30080
      protocol: TCP
    - name: https
      port: 30443
      targetPort: 30443
      protocol: TCP
    service:
      type: ClusterIP          # NodePort → ClusterIP
      ports:
      - name: http2
        port: 80
        targetPort: 30080      # svc 内部访问仍走 80
      - name: https
        port: 443
        targetPort: 30443
    hostNetwork: true          # pod 直接用节点网络栈,监听节点 30080/30443
    dnsPolicy: ClusterFirstWithHostNet   # 必须加,否则集群 DNS 解析失效
    replicas: 3                # 3 台入口节点各一个 pod
    nodeSelector:
      higress-ingress: "true"
```

```bash
helm upgrade higress ./higress-2.2.4.tgz -n higress-system -f higress-values.yaml
```

如果升级后发现 chart 对 `hostNetwork`/`ports` 的 values 覆盖不生效，手动补齐(下次 upgrade 前记得把 values 同步):

```bash
kubectl -n higress-system patch deploy higress-gateway --type=strategic -p \
'{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet","nodeSelector":{"higress-ingress":"true"}}}}}'

kubectl -n higress-system patch svc higress-gateway --type=json \
-p '[{"op":"replace","path":"/spec/type","value":"ClusterIP"},{"op":"replace","path":"/spec/ports/0/targetPort","value":30080},{"op":"replace","path":"/spec/ports/1/targetPort","value":30443}]'
```

### 第 3 步：验证(切流量前必须全绿)

```bash
# pod 分布在 3 台节点
kubectl -n higress-system get pod -l app=higress-gateway -o wide

# svc 已是 ClusterIP,不再有 nodePort
kubectl -n higress-system get svc higress-gateway -o wide

# 在入口节点本机验证 hostNetwork 监听(关键)
ss -lntp | grep -E ':30080 |:30443 '
curl -s -H "Host: console.higress.local" http://localhost:30080/
```

> 端口 >1024,envoy 不需要 NET_BIND_SERVICE 特权，一般不会遇到权限问题。

### 第 4 步：观察 ELB

ELB 后端组、端口、健康检查**都不用动**——后端还是节点 IP:30080,只是这个端口现在由 envoy(hostNetwork)直接应答，而不是 kube-proxy 的 NodePort 转发。切 pod 期间会有几秒钟 endpoint 重建，健康检查可能闪断一次，console 这种低频管理流量无感。

### 第 5 步：收尾

```bash
# console 自己的 NodePort 一并收掉
kubectl -n higress-system patch svc higress-console -p '{"spec":{"type":"ClusterIP"}}'

# 全集群确认没有残留 NodePort
kubectl get svc -A | grep NodePort
```

最后 Windows 上 `curl http://console.higress.local/` 确认 console 登录页正常，浏览器强刷即可。

**回滚**：values 改回原样(ports 80/443、type NodePort、去掉 hostNetwork)重新 `helm upgrade`,一分钟内恢复。