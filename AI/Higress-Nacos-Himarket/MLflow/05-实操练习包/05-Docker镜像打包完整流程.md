# Docker 镜像打包完整流程（mlflow-practice:v1）

> 目标：把「mlflow 客户端 + 训练库」打包成一张镜像推到 Harbor，
> 供集群内训练 Pod 使用。命令可直接复制执行。
>
> **先明确角色**：这张镜像是给**训练客户端**用的；
> 集群里正在运行的 MLflow 服务端（`mlflow:v2.17.2`）是记账员，
> 不需要训练库，**永不改动**。

---

## 0. 先选对训练环境（什么时候才需要做镜像）

| 方式 | 需要准备 | 适合场景 |
|---|---|---|
| **本机训练**（Windows 直接跑） | pip 装 3 个包，**无需任何镜像** | 练习、轻量实验（见第 7 节） |
| **集群内训练**（Pod 里跑） | 本文档的练习镜像 | 正式训练、GPU 机器、Jenkins 自动化 |

两种方式的训练记录都会发到**同一个 MLflow server**——训练端在哪执行无所谓，台账只有一个。

---

## 1. 前置条件

| 条件 | 说明 |
|---|---|
| 一台装有 Docker 的机器 | Windows 装 Docker Desktop，或任意 Linux 服务器/跳板机。**K8s 节点本身一般没有 docker 命令，别在节点上 build** |
| 外网访问 | 拉基础镜像 + pip 下载库（场景 B 中只需要构建机有） |
| Harbor 权限 | 能登录 `harbor.ai.cnpc` 并对 `ai-platform-poc` 项目有推送权限 |

外网和 Harbor 权限可以在**不同机器**上（对应场景 B）。

---

## 2. Dockerfile（正式版，已就位于本目录 `05-Dockerfile.practice`）

```dockerfile
# 底座默认用 Harbor 里已有的镜像；纯外网机器构建时：
#   --build-arg BASE=ghcr.io/mlflow/mlflow:v2.17.2
ARG BASE=harbor.ai.cnpc/ai-platform-poc/mlflow:v2.17.2
FROM ${BASE}

ARG SKLEARN_VERSION=1.5.2
ARG MATPLOTLIB_VERSION=3.9.2
ARG PIP_INDEX=https://pypi.org/simple

LABEL maintainer="ops" \
      description="MLflow 2.17.2 client + scikit-learn training image (practice/CI)"

RUN pip install --no-cache-dir \
      -i ${PIP_INDEX} \
      "scikit-learn==${SKLEARN_VERSION}" \
      "matplotlib==${MATPLOTLIB_VERSION}"

# 构建期自检：import 失败则构建直接失败，防止坏镜像进 Harbor
RUN python -c "import mlflow, sklearn, matplotlib; \
print('client-image-ok | mlflow', mlflow.__version__, '| sklearn', sklearn.__version__, '| matplotlib', matplotlib.__version__)"
```

设计要点：**版本全部锁定**（可复现）、**底座/源可参数化**（内外网机器通用）、
**构建自检**（坏镜像进不了 Harbor）、镜像增量只有约 60MB。

---

## 3. 场景 A：一台机器同时有外网 + Harbor 权限（最简路径）

```bash
cd <05-Dockerfile.practice 所在目录>

# 构建（国内网络加速版见注释）
docker build -f 05-Dockerfile.practice -t mlflow-practice:v1 .
# 加速版：
# docker build -f 05-Dockerfile.practice \
#   --build-arg PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple \
#   -t mlflow-practice:v1 .

# 打 tag 并推送
docker tag mlflow-practice:v1 harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1
docker login harbor.ai.cnpc
docker push harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1
```

---

## 4. 场景 B：外网机器与 Harbor 隔离（你们导 mlflow 镜像的同款流程）

```bash
# ===== ① 外网构建机上 =====
docker build -f 05-Dockerfile.practice \
  --build-arg BASE=ghcr.io/mlflow/mlflow:v2.17.2 \
  -t mlflow-practice:v1 .
docker save -o mlflow-practice-v1.tar mlflow-practice:v1

# ===== ② 传输 tar 包 =====
# U 盘 / 内网 scp，走你们当初把 mlflow:v2.17.2 镜像弄进来的同一条路

# ===== ③ 能访问 Harbor 的机器上 =====
docker load -i mlflow-practice-v1.tar
docker tag mlflow-practice:v1 harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1
docker login harbor.ai.cnpc
docker push harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1
```

---

## 5. 集群内验证镜像

```bash
kubectl -n ml-platform run practice-check --rm -it --restart=Never \
  --image=harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1 \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"harbor-secret"}]}}' \
  -- python -c "import mlflow,sklearn,matplotlib;print('ok',mlflow.__version__,sklearn.__version__,matplotlib.__version__)"
```

打印 `ok 2.17.2 1.5.2 3.9.2` 即镜像可用，可以进《05-MLflow真模型实操手册.md》第二节。

---

## 6. 常见错误速查

| 报错 | 原因 | 解决 |
|---|---|---|
| `docker: command not found` | 机器没装 Docker | Windows 装 Docker Desktop；或找一台有 Docker 的 Linux 机器 |
| pip 安装超时/极慢 | 直连 pypi.org 慢 | `--build-arg PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple` |
| `requires a different Python version` | 底座镜像 Python 太老（3.8） | 先 `-- python --version` 查底座版本；降版 `--build-arg SKLEARN_VERSION=1.3.2` + `MATPLOTLIB_VERSION=3.7.5` |
| push 报 `http: server gave HTTP response` / TLS | Harbor 是 http 或自签证书 | 配 Docker 的 `insecure-registries`（你们推 mlflow 镜像时已解决，照抄那台机器的配置） |
| push 报 `denied` | 未登录或无项目权限 | `docker login`；找 Harbor 管理员开 `ai-platform-poc` 推送权限 |
| K8s 里 `ImagePullBackOff` | tag 不存在或漏 harbor-secret | 核对 push 是否成功、tag 拼写；起 Pod 带 `--overrides` |
| 节点架构不匹配（罕见） | 构建机是 ARM（如 Apple Silicon） | 构建 加 `--platform linux/amd64` |

---

## 7. 不做镜像也行：Windows 本机训练模式

**回答你的问题：是的**——不在集群里训练，就可以直接在你的 Windows 电脑上
pip 装这几个包来训练。MLflow 的设计就是**训练端在哪都行**：

```powershell
# ① 装包（PowerShell / CMD 均可）
pip install mlflow==2.17.2 scikit-learn==1.5.2 matplotlib==3.9.2

# ② 连服务端（二选一）
#    a) 已有网关域名（如 Higress 暴露的 mlflow.example.com）——推荐，免隧道：
$env:MLFLOW_TRACKING_URI = "http://mlflow.example.com"
#    b) 无域名时开隧道（窗口保持别关）：
# kubectl -n ml-platform port-forward svc/mlflow 5000:5000
# $env:MLFLOW_TRACKING_URI = "http://127.0.0.1:5000"
# CMD 写法： set MLFLOW_TRACKING_URI=http://<域名或127.0.0.1:5000>
# Git Bash 写法： export MLFLOW_TRACKING_URI=...

# ③ 验证连通后直接跑（脚本就在本目录）
curl http://mlflow.example.com/health        # 返回 OK 即通

cd C:\Users\Windows\WorkBuddy\cicd\mlflow-hands-on
python 05-train_real.py
```

> 走域名时的两个注意点（网关侧完整说明见《MLflow-运维手册》第 7 节）：
> ① Higress 路由要对 `mlflow:5000` **全路径转发**（artifact 上传走的是
>    `/api/2.0/mlflow-artifacts/...` 接口，漏了这条路径参数和图表会上传失败）；
> ② 若网关配了 HTTPS 且用的是企业自签证书，客户端报 SSL 错误时临时设
>    `$env:MLFLOW_TRACKING_INSECURE_TLS = "true"`（正式做法是把企业 CA 装进信任链）。

跑完打开 MLflow UI：记录出现在**同一个** `real-model-practice` 实验里，
和集群内训练的结果完全一样、完全互通。

**怎么选**：

| 场景 | 推荐 |
|---|---|
| 练手、轻量实验、验证流程 | 本机 pip 直装（10 分钟见效，不用碰 Docker） |
| 正式训练、需要 GPU、Jenkins 流水线自动训练 | 集群 + 本文档的镜像（环境锁定、可复现） |
