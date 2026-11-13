# 从零新建一个 MCP Server 并接入 HiChat

> **状态：2026-11-11 16:14 全链路实跑通过。** HiChat 勾选后模型自动调用 `get_time`，
> 返回「工具执行完成」。本文所有命令均经现场验证，可直接复用。
>
> 目标：不依赖任何已有产品、不依赖 Nacos 里那三条半残的 demo、不碰 higress 白名单，
> 从零落地一个自己写的 MCP，在 HiChat 里能真正调到。
>
> 命名一律用 `mini-mcp`（Deployment / Service / ConfigMap）和 `demo-time-mcp`（HiMarket 产品名），
> 跟旧的 `test` / `tt1028` / `test-hig-local` 完全不重叠，出问题一眼能分清是谁。

## 已验收的配置（照抄即可复现）

| 项 | 值 |
|---|---|
| 集群 / 命名空间 | HiMarket 集群 / `himarket` |
| 镜像 | `<HARBOR>/ai-platform/kubeflow/python:3.7`（实际 python 3.7.17） |
| 代码挂载 | ConfigMap `mini-mcp-src`，key `11-mini_mcp_py2.py` → `/app/11-mini_mcp_py2.py` |
| 启动命令 | `/bin/sh -c "exec python3 /app/11-mini_mcp_py2.py 8765 \|\| exec python ..."` |
| Service | `mini-mcp`，**ClusterIP**（本集群禁用 NodePort），端口 8765 |
| HiMarket 产品 | 名称 `demo-time-mcp`，类型 MCP Server，类别 agent类别 |
| 关联 API 方式 | **标准创建**（不是 M-JSON 导入，也不是 HTTP 转 MCP） |
| 传输方式 / 地址 | `Streamable HTTP` / `http://mini-mcp.himarket.svc.cluster.local:8765/mcp` |
| 结果 | 工具列表出现 `get_time` / `echo` / `add`；HiChat 调用成功 |

> 关键结论：自建 MCP 走「产品壳 + 关联 API 标准创建」这条路，全程不经过 Nacos 和 higress。
> 三条「导入」入口都要求外部先注册，只有「标准创建」不依赖任何外部注册中心。

---

## 阶段 0　前置条件（一句话）

跳板机上要有 `kubectl` 且 kubeconfig 能访问 `himarket` 命名空间；`11-mini_mcp_py2.py`
和 `21-mini-mcp.yaml` 两个文件已通过 JumpServer 文件管理传到同一目录。
这两条不满足，后面全部白做。

---

## 阶段 1　手动部署到 himarket 命名空间

全程手工，10 条命令。每一步都标了**预期输出**，对不上就别往下走。

### 1.1 上传文件

只用两个文件，经 JumpServer 文件管理传到跳板机同一个目录（下文以 `/root/mcp/` 为例）：

- `11-mini_mcp_py2.py` —— MCP 服务端（py2/py3 双兼容，469 行）
- `21-mini-mcp.yaml` —— Deployment + Service 清单

`12-test-mini-mcp.sh` 也建议一起传，阶段 2 要用。

```bash
cd /root/mcp
ls -l 11-mini_mcp_py2.py 21-mini-mcp.yaml
# 预期：两个文件都在，11-mini_mcp_py2.py 约 16KB
```

### 1.2 确认集群和命名空间

```bash
kubectl config current-context
kubectl -n himarket get deploy
# 预期：列得出 himarket-server / himarket-web 之类
```

如果 `himarket` 命名空间查不到，说明 kubeconfig 指向的是模型集群，先切回去，后面全部白做。

### 1.3 取 Harbor 前缀

```bash
kubectl -n himarket get deploy himarket-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# 预期：harbor.example.internal/ai-platform/himarket-server:v0.8.2
#       第一段 harbor.example.internal 就是 <HARBOR>
```

### 1.4 取镜像拉取凭据名

```bash
kubectl -n himarket get deploy himarket-server \
  -o jsonpath='{.spec.template.spec.imagePullSecrets}{"\n"}'
# 预期： [{"name":"harbor-secret"}]   或   （空）
```

- 有 name → 记住它，1.5 要填。
- 输出为空 → Harbor 允许匿名拉取，清单里那两行保持注释状态即可。

### 1.5 改清单两处

```bash
cd /root/mcp

# ① 替换 Harbor 前缀（把 harbor.example.internal 换成 1.3 实际读到的）
sed -i 's|<HARBOR>|harbor.example.internal|' 21-mini-mcp.yaml

# ② 确认镜像行
grep -n 'image:' 21-mini-mcp.yaml
# 预期：  image: harbor.example.internal/ai-platform/kubeflow/python:3.7
#         且前面没有 < 尖括号
```

如果 1.4 有凭据名，把这两行的注释去掉（`vi 21-mini-mcp.yaml` 找到 34-37 行附近）：

```yaml
      imagePullSecrets:
        - name: harbor-secret        # 换成 1.4 读到的实际名字
```

> 这两行现在是注释状态，长这样：
> `# imagePullSecrets:` / `#   - name: harbor-secret`
> 只删掉行首的 `# `，不要把缩进弄乱 —— `imagePullSecrets` 要和 `containers:` 同列。

### 1.6 Service 类型：ClusterIP（本集群禁用 NodePort）

清单里 Service 已经是 `type: ClusterIP`，且 `nodePort` 那行是**注释掉的**。
这两点必须同时成立 —— ClusterIP 下如果留着一个生效的 `nodePort` 字段，
`kubectl apply` 会被 API Server 直接拒绝：

```
The Service "mini-mcp" is invalid: spec.ports[0].nodePort: Forbidden:
may not be used when `type` is 'ClusterIP'
```

确认一下当前状态：

```bash
grep -n -A3 'kind: Service' 21-mini-mcp.yaml | head -6
grep -n 'type: ClusterIP' 21-mini-mcp.yaml          # 必须命中
grep -n '^      nodePort:' 21-mini-mcp.yaml         # 必须无命中（有 # 前缀才算注释掉）
```

因为只有 ClusterIP，调用方必须与它同集群。这正好成立：`himarket-server` 就在
`himarket` 命名空间里，直接走 svc 域名。代价是跳板机不能直接 curl，验证方式见 2.3。

### 1.7 创建 ConfigMap（代码进集群）

**必须在 `11-mini_mcp_py2.py` 所在目录执行**，`--from-file` 的 key 决定容器里挂出来的文件名，写错了容器启动会报 `can't open file '/app/11-mini_mcp_py2.py'`。

```bash
cd /root/mcp
kubectl -n himarket create configmap mini-mcp-src \
  --from-file=11-mini_mcp_py2.py=./11-mini_mcp_py2.py \
  --dry-run=client -o yaml | kubectl apply -f -
# 预期：configmap/mini-mcp-src created

# 核对 key 名和大小
kubectl -n himarket get configmap mini-mcp-src -o jsonpath='{.data}'
# 预期：{"11-mini_mcp_py2.py":"#!/usr/bin/env python\n# -*- coding: utf-8 -*-..."}
```

### 1.8 部署

```bash
kubectl apply -f 21-mini-mcp.yaml
# 预期：
#   deployment.apps/mini-mcp created
#   service/mini-mcp created
```

### 1.9 等就绪

```bash
kubectl -n himarket rollout status deploy/mini-mcp --timeout=120s
# 预期：deployment "mini-mcp" successfully rolled out
```

报错就跑这两条看原因：

```bash
kubectl -n himarket get pod -l app=mini-mcp -o wide
kubectl -n himarket describe pod -l app=mini-mcp | tail -25
```

### 1.10 看启动日志，确认解释器走对了

```bash
kubectl -n himarket logs deploy/mini-mcp --tail=15
```

预期看到（重点是 `python :` 那行 —— 说明 `python3` 存在，没退回 `python`）：

```
mini-mcp 1.1.0 ready
  python : 3.7.x
  listen : 0.0.0.0:8765
  health : http://127.0.0.1:8765/
  mcp    : http://127.0.0.1:8765/mcp   (Streamable HTTP)
  sse    : http://127.0.0.1:8765/sse   (旧式 SSE)
  tools  : add, echo, get_time
```

到这里部署就结束了，**还没碰 HiMarket**。

---

## 阶段 2　两层验证 + 一次握手（**不要跳，这里过了后面基本不会失败**）

### 2.1 容器自己是否正常

```bash
kubectl -n himarket logs deploy/mini-mcp --tail=20
# 期望：
#   mini-mcp 1.1.0 ready
#     python : 3.7.x
#     listen : 0.0.0.0:8765
#     mcp    : http://127.0.0.1:8765/mcp   (Streamable HTTP)
#     sse    : http://127.0.0.1:8765/sse   (旧式 SSE)
#     tools  : add, echo, get_time
```

### 2.2 集群内可达（这是 HiChat 实际要走的路，**最关键的一条**）

```bash
kubectl -n himarket exec deploy/himarket-server -- \
  curl -sS -m 5 http://mini-mcp.himarket.svc.cluster.local:8765/
# 期望：{"status": "ok", ... "tools": ["add", "echo", "get_time"] ...}
```

这一条通，等于已经证明了 HiChat 能连到 MCP —— 因为 MCP 客户端就住在 `himarket-server`
进程里。如果容器里没装 curl，换成：

```bash
kubectl -n himarket exec deploy/himarket-server -- \
  wget -qO- http://mini-mcp.himarket.svc.cluster.local:8765/
```

### 2.3 完整 MCP 握手（用端口转发把服务临时拉到跳板机本地）

ClusterIP 在集群外不可达，所以本地直接用端口转发，这样 `12-test-mini-mcp.sh`
能原样跑（它测的是协议，不是网络）：

```bash
# 终端 A：占住不关
kubectl -n himarket port-forward svc/mini-mcp 8765:8765
# 期望：Forwarding from 127.0.0.1:8765 -> 8765
```

```bash
# 终端 B：
cd /root/mcp
sh 12-test-mini-mcp.sh 127.0.0.1:8765
```

7 步全过（initialize / tools/list 有三个工具 / get_time 返回真实时间 /
`GET /mcp` 返回 405）才说明这个 MCP 是**真的能用**，而不是端口通。

测完 `Ctrl-C` 关掉终端 A 的端口转发。它只是测试用的临时通道，
不要留着当生产入口 —— HiMarket 走的是 svc 域名，不经过它。


---

## 阶段 3　在 HiMarket 建产品

进「API 产品」→ 切到 **MCP Server** 标签 → 点右上角 **「+ 创建」**（不是「导入」）。

> 三条「导入」都要求外部已先注册（网关/Nacos/别的门户），
> 从零开始自建的 MCP 只有「+ 创建」是干净的入口。
>
> ⚠️ 实测确认：这个创建弹窗**只有 名称 / 描述 / 类型 / 产品类别 / Icon 五项，没有地址字段**。
> 它建的是"产品壳"，MCP 的服务地址要进详情页再配。
> 所以旧的 `test` 产品显示「待配置」就是卡在这一步——壳建了，地址从没填过。

### 3.1 填壳

| 字段 | 填什么 |
|---|---|
| 名称 | `demo-time-mcp` |
| 描述 | 自建演示 MCP：查当前时间、文本回显、两数相加 |
| 类型 | `MCP Server`（默认已是） |
| 产品类别 | `agent类别` 勾上；想在大模型分组也露出就把 `大模型类别` 一起勾（多选，无副作用） |
| Icon 设置 | 留空即可，非必填 |

点「确定」。

### 3.2 进详情页配 MCP 服务地址（真正关键的一步）

创建成功后点进 `demo-time-mcp` 详情页，找 **「MCP Server 配置」/「服务配置」/「关联 MCP Server」/「工具」** 这类 tab 或按钮。
能看到「传输方式 + 服务地址 URL」的输入框，就按下面填；如果那里只能从下拉里挑一个已注册的 MCP Server，
说明这版 HiMarket 必须先从 Nacos 发现，走 3.3。

| 字段 | 填什么 |
|---|---|
| 传输方式 | `Streamable HTTP` |
| 服务地址 | `http://mini-mcp.himarket.svc.cluster.local:8765/mcp` |

- **必须用完整域名** `mini-mcp.himarket.svc.cluster.local`，不要写 `mini-mcp.himarket:8765`。
  后者依赖 search domain 拼接，某些 HTTP 客户端拼不出来就报 UnknownHost。
- **不能填节点 IP**：Service 是 ClusterIP，节点 IP 上什么都没监听，填了必然连接超时。
- 保存 → 点「刷新工具列表」→ 应出现 `get_time`、`echo`、`add` 三个。
- 只有 SSE 选项时：传输方式选 `SSE`，地址改成
  `http://mini-mcp.himarket.svc.cluster.local:8765/sse`（同一份代码两种都支持）。
- 刷新工具列表为空：说明 HiMarket 连不上或握手不对，回去看 2.2、2.3 的结果，并用
  `kubectl -n himarket logs deploy/himarket-server --tail=100 | grep -i mcp` 看服务端报错。

### 3.3 分支 B：必须走 Nacos 发现（详情页没有地址输入框时）

1. **Nacos 注册实例**：服务名 `mini-mcp`，分组 `mcp-endpoints`，
   IP/地址填 `http://mini-mcp.himarket.svc.cluster.local:8765`（参考现有 `test` 实例的填法，
   它是 `http://www.baidu.com:80` 这种带 scheme 的形式）。
   注册后确认实例是**健康**状态。
   > 这里能填 svc 域名，前提是 higress 也在这个集群、能解析 `*.svc.cluster.local`。
   > 如果 higress 在另一个集群，这条路就走不通，只能放弃 Nacos 方案、改用 3.2 的直连。
2. **补 mcpbridge 白名单**（这是之前一直没生效的那一步，注意 `allowMcpServers` 必须加进去）：

   ```bash
   kubectl -n himarket get mcpbridge default -o jsonpath='{.spec.registries}' | python3 -m json.tool
   ```
   记下 `company-nacos` 这个 registry 在数组里的下标（之前是 2），然后：

   ```bash
   kubectl -n himarket patch mcpbridge default --type json -p '[
    {"op":"replace","path":"/spec/registries/2/nacosGroups","value":["DEFAULT_GROUP","mcp-endpoints"]},
    {"op":"replace","path":"/spec/registries/2/allowMcpServers","value":["mini-mcp"]}]'
   ```
   ⚠️ 这一段是**整体替换**，如果原来还有别的 MCP 在用，要把它们的名字一起写进 `allowMcpServers` 数组，
   否则会把别人关掉。
3. 回详情页选「关联 MCP Server」→ 选 `mini-mcp`。

---

## 阶段 4　发布 + 订阅

1. 产品详情页 → **发布** → 选门户（`demo`）→ 确认状态变「已发布」。
2. 用 Consumer 账号（或你的账号切到消费者视角）在门户里 **订阅** 这个 MCP 产品。
3. 订阅没审批通过前，HiChat 里勾了也调不通。

---

## 阶段 5　HiChat 验证

新开一个对话 → 勾选 **只有** `demo-time-mcp` 这一个 MCP（旧的 `test` 千万别勾，它是空指针来源）→ 提问：

> 现在几点了？

期望：模型决定调用 `get_time`，返回形如「Asia/Shanghai 当前时间：2026-11-11 15:20:31（UTC+08:00）」。
追问一句「把 hello mcp 回显给我」验证 `echo`。

---

## 验收清单

- [ ] Pod 1/1 Running，日志出现 `ready`，且 `python :` 是 3.7.x
- [ ] Service 是 `type: ClusterIP`，且没有生效的 `nodePort` 字段
- [ ] 2.2 集群内 `himarket-server` curl 返回 `status: ok`
- [ ] 2.3 端口转发后七个测试步骤全过
- [ ] HiMarket 产品工具列表出现 3 个工具
- [ ] 产品「已发布」+ 「已订阅」
- [ ] HiChat 勾选后能返回真实时间

---

## 速查

| 现象 | 判断 | 处理 |
|---|---|---|
| apply 报 `nodePort: Forbidden` | ClusterIP 下 nodePort 没注释 | 把 `nodePort:` 那行前面加 `#` |
| `ImagePullBackOff` | 镜像地址或凭据不对 | 核对 1.3/1.4 的输出；补 `imagePullSecrets` |
| `CrashLoopBackOff` | 脚本没挂上或解释器路径不对 | `kubectl -n himarket logs` 看报错；`kubectl -n himarket exec deploy/mini-mcp -- ls -l /app` |
| ConfigMap 里文件名不对 | `--from-file=` 的 key 决定文件名 | 必须是 `11-mini_mcp_py2.py` |
| 2.2 `curl: command not found` | 容器里没装 curl | 换 `wget -qO-`；或用 port-forward 在本地测 |
| 2.3 port-forward 报 `address already in use` | 本地 8765 被占 | 换映射：`port-forward svc/mini-mcp 18765:8765`，再测 `127.0.0.1:18765` |
| 2.3 initialize 失败但 2.2 正常 | 路径不对 | 确认用的是 `/mcp` 不是 `/` |
| 工具列表刷新为空 | HiMarket 连不上或响应格式不符 | 看 himarket-server 日志里的 MCP 相关异常；确认地址是 svc 完整域名 |
| 详情页填节点 IP 后连接超时 | ClusterIP 在节点 IP 上没有监听 | 改回 `mini-mcp.himarket.svc.cluster.local` |
| HiChat 勾选后 500 / 空指针 | 是旧 `test` 产品在起作用 | 只勾新 MCP；或先把 `test` 产品删掉 |
| HiChat 不调用工具只闲聊 | 模型没开 tool 能力 | 换 Qwen3-32B 并在 vLLM 加 `--enable-auto-tool-choice --tool-call-parser hermes` |
