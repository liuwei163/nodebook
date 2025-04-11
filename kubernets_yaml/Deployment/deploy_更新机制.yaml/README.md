1. 滚动更新（Rolling Update）
这是 Deployment 默认的更新策略。滚动更新会逐步替换旧的 Pod 副本为新的 Pod 副本，而非一次性全部替换。此过程能确保应用在更新期间持续可用。

关键参数
maxUnavailable：    在更新过程中，允许不可用的 Pod 副本的最大数量。可以是一个绝对值，也可以是 Pod 总数的百分比。
maxSurge：          在更新过程中，允许超过期望 Pod 副本数的最大数量。同样可以是绝对值或百分比。

示例:
    假设一个 Deployment 当前有 5 个 Pod 副本，maxUnavailable 设置为 1，maxSurge 设置为 1。更新时，首先会创建一个新的 Pod 副本，使总副本数变为 6。
    接着，删除一个旧的 Pod 副本，此时可用副本数仍为 5。之后，重复这个过程，直到所有旧的 Pod 副本都被新的 Pod 副本替换。

2. 重建更新（Recreate）
这种更新策略会先删除所有旧的 Pod 副本，然后再创建新的 Pod 副本。使用此策略时，应用在更新期间会有一段时间不可用。
适用场景：当应用的新版本与旧版本不兼容，或者更新过程中需要进行一些特殊的初始化操作时，可以使用重建更新策略。

可以*通过命令kubectl  set* 或者 *直接edit  yaml文件 修改文件内容*的方式进行更新


示例滚动更新：
1. 创建初始 Deployment
在进行滚动更新前，你得先创建一个初始的 Deployment。以下是一个简单的示例 YAML 文件，用于创建一个运行 Nginx 服务的 Deployment：
```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.14.2
        ports:
        - containerPort: 80
```
将上述内容保存为 nginx-deployment.yaml 文件，然后使用以下命令创建 Deployment：

kubectl apply -f nginx-deployment.yaml
2. 查看 Deployment 状态
创建完成后，你可以使用以下命令查看 Deployment 的状态：
kubectl get deployments nginx-deployment

还可以查看 ReplicaSet 和 Pod 的状态：

kubectl get replicasets
kubectl get pods

3. 触发滚动更新
要触发滚动更新，通常是更新 Deployment 中容器的镜像版本。你可以通过以下几种方式实现：
方式一：直接编辑 YAML 文件
打开 nginx-deployment.yaml 文件，将 image 字段的值从 nginx:1.14.2 改为 nginx:1.16.1：
```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.16.1  # 更新镜像版本
        ports:
        - containerPort: 80
```

然后使用 kubectl apply 命令应用更改：
kubectl apply -f nginx-deployment.yaml

方式二：使用 kubectl set image 命令
你也可以不编辑 YAML 文件，直接使用 kubectl set image 命令更新镜像：

kubectl set image deployment/nginx-deployment nginx=nginx:1.16.1
这里的 nginx 是容器的名称，nginx:1.16.1 是新的镜像版本。
4. 监控滚动更新过程
在触发滚动更新后，你可以使用以下命令监控更新过程：
bash
kubectl rollout status deployment/nginx-deployment
该命令会实时显示更新的进度，直到更新完成。
你还可以使用以下命令查看 Deployment 的事件信息，了解更新过程中的详细情况：
bash
kubectl describe deployment nginx-deployment
5. 回滚滚动更新
如果在更新过程中发现新版本存在问题，你可以使用以下命令回滚到上一个稳定版本：
bash
kubectl rollout undo deployment/nginx-deployment
如果你想回滚到指定的历史版本，可以先查看 Deployment 的历史版本：
bash
kubectl rollout history deployment/nginx-deployment
然后使用以下命令回滚到指定版本：
bash
kubectl rollout undo deployment/nginx-deployment --to-revision=2
这里的 2 是你要回滚到的版本号。
6. 调整滚动更新参数
你可以通过修改 Deployment 的 spec.strategy.rollingUpdate 字段来调整滚动更新的参数，如 maxUnavailable 和 maxSurge：
yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.16.1
        ports:
        - containerPort: 80
maxUnavailable：在更新过程中，允许不可用的 Pod 副本的最大数量。可以是一个绝对值，也可以是 Pod 总数的百分比。
maxSurge：在更新过程中，允许超过期望 Pod 副本数的最大数量。同样可以是绝对值或百分比。
修改完成后，使用 kubectl apply 命令应用更改。