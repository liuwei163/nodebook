# Higress 2.2.4 离线部署

> 环境：离线K8s，私有仓库 `192.168.208.127/k8s-images`，NodePort 暴露网关，关闭监控组件

## 1、higress-values.yaml 完整内容

```yaml
# Higress 安装自定义配置(离线环境 + NodePort)
global:
  # 本地仓库地址,覆盖 core 组件 (gateway/higress/pilot) 的 registry
  hub: 192.168.208.127/k8s-images
  # 本地集群标记true(关闭部分对云环境的依赖)
  # 改为false 运行扩容网关副本
  local: false
  o11y:
    # 关闭可观测性组件(grafana/prometheus/loki),它们需要 PVC 且环境无 StorageClass
    enabled: false

# Higress Gateway(数据面)——位于子 chart higress-core,需用前缀 higress-core 覆盖
higress-core:
  gateway:
    replicas: 3
    nodeSelector:
      higress-ingress: "true"
    service:
      # 用 NodePort 对外暴露(集群无 LoadBalancer)
      type: NodePort
      ports:
        - name: http2
          port: 80
          targetPort: 80
          protocol: TCP
          # NodePort 端口(http)
          nodePort: 30080
        - name: https
          port: 443
          targetPort: 443
          protocol: TCP
          # NodePort 端口(https)
          nodePort: 30443

# Higress Console(管理控制台)
higress-console:
  # console 镜像独立配置,指向本地仓库
  image:
    repository: 192.168.208.127/k8s-images/higress/console
    tag: "2.2.4"
    pullPolicy: IfNotPresent
  service:
    # 控制台用 NodePort 暴露
    type: ClusterIP
    port: 8080
  # o11y 子项默认 enabled:false,显式关闭以避免 PVC
  global:
    o11y:
      enabled: false
  pvc:
    rwxSupported: false
```

## 2、前置检查

```bash
# 给网关节点打标签，网关Pod只会调度到带此标签节点
kubectl label node <节点名称> higress-ingress=true

# 验证标签
kubectl get nodes --show-labels | grep higress-ingress
```

## 3、部署命令

```bash
# 进入工作目录
cd /root/higress

# 创建命名空间
kubectl create ns higress

# helm离线安装 higress，使用上面这份higress-values.yaml配置
helm install higress ./higress-2.2.4.tgz -n higress -f higress-values.yaml
```

## 4、查看部署状态

```bash
# 查看pod，等待全部Running
kubectl get pods -n higress -w

# 查看service，确认30080(http)、30443(https) NodePort端口
kubectl get svc -n higress
```

## 5、访问说明

- 网关入口：`节点IP:30080`（http），`节点IP:30443`（https）
- Higress 控制台：ClusterIP 类型，集群内访问，通过网关配置ingress路由来进行访问

## 6、卸载命令

```bash
helm uninstall higress -n higress
```

## 简要说明

- `global.hub`：镜像从本地私有仓库拉取，不走外网
- `service.type: NodePort`：离线无 LB，用节点端口暴露 80/443
- `nodeSelector`：网关 Pod 只调度到带 `higress-ingress=true` 标签的节点
