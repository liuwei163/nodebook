# 添加官方仓库（以 Higress 为例）
helm repo add higress.io https://higress.io/helm-charts

# 更新本地仓库索引（获取最新版本的 chart）
helm repo update

# 查看已添加的仓库列表
helm repo list

# 搜索仓库中的 chart
helm search repo higress

# 查看某个 chart 的所有可用版本
helm search repo higress.io/higress --versions

# 检查 values.yaml 语法是否有问题
helm lint higress.io/higress -f values.yaml

# 将渲染后的 K8s YAML 打印到终端，查看是否正确（不部署到集群）
helm template higress higress.io/higress -n higress-system -f values.yaml

# 使用 --dry-run 模拟升级（不实际改变集群状态）
helm upgrade higress higress.io/higress -n higress-system -f values.yaml --dry-run

# 基本安装
helm install <release-name> <chart-name> -n <namespace> --create-namespace

# 针对你的场景（使用自定义的 values.yaml 安装 Higress）
helm install higress higress.io/higress -n higress-system --create-namespace -f values.yaml

# 查看所有命名空间下已安装的 release
helm list -A

# 查看指定命名空间下的 release
helm list -n higress-system

# 查看某个 release 的详细状态
helm status higress -n higress-system

# 升级现有的 release
helm upgrade <release-name> <chart-name> -n <namespace> -f values.yaml

# 针对你的场景：升级 Higress
helm upgrade higress higress.io/higress -n higress-system -f values.yaml


helm upgrade --install higress higress.io/higress -n higress-system -f values.yaml

# 查看 release 的历史版本记录（可以看到版本号 1, 2, 3...）
helm history higress -n higress-system

# 回滚到指定的版本号（例如回滚到版本 1）
helm rollback higress 1 -n higress-system

helm uninstall higress -n higress-system