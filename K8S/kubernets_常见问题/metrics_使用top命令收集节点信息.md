# 1. 下载并替换国内镜像
curl -LO https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
sed -i 's|registry.k8s.io/metrics-server/metrics-server|registry.aliyuncs.com/google_containers/metrics-server|g' components.yaml

# 2. （可选）添加跳过 TLS 验证（私有集群）
sed -i '/args:/a \        - --kubelet-insecure-tls' components.yaml

# 3. 部署
kubectl apply -f components.yaml

# 4. 验证
kubectl get pods -n kube-system -l k8s-app=metrics-server
kubectl top nodes