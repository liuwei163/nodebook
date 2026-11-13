# MLflow 真模型实操手册（集群内 · 离线环境）

> 目标：练**真模型**——真的训练、真的模型文件、训练完自动注册、从注册表取回、
> 最后把模型变成 REST 服务。全程在集群内操作，你的电脑仍然只出 kubectl 和浏览器。
>
> 前置：建议先完成《05-MLflow上手实操手册.md》（纯客户端练习），本手册是其"进阶篇"。
>
> 与纯客户端练习的本质区别：这次会往 MLflow 的 artifact 存储（NFS）里**写真实的模型文件**，
> 并走通"训练即注册"的完整闭环——这正是 MLflow 设计的标准路径。

---

## 一、物料准备：一张带训练库的镜像（一次性工作）

### 先搞清楚：这两个库到底要装在哪？（关键认知）

> **规则：训练脚本在哪个 Pod 里跑，库就得在那个 Pod 的镜像里。**
>
> - **MLflow 服务端（mlflow:v2.17.2 部署）**：不需要 sklearn/matplotlib，**一个字节都不用改**。
>   它只是"记账员"，负责接收参数、指标、文件——不参与训练。
> - **训练客户端（练习 Pod）**：`05-train_real.py` 里有 `from sklearn...`（训练）和
>   `import matplotlib`（画图），这两个 import 是在客户端进程里执行的，
>   所以**运行训练脚本的镜像**必须带这些库。
> - 所谓"把库打包进镜像"，做法是拿 mlflow 官方镜像当底，**加两个库做成一张新镜像
>   `mlflow-practice:v1`，只给客户端用**——服务端镜像和现有 Deployment 完全不动。
>   `mlflow` 本身也必须在客户端镜像里（它负责把数据上报给服务端）。
>
> | 角色 | 镜像 | 需要什么 |
> |---|---|---|
> | 记账员（服务端，已在跑） | mlflow:v2.17.2 | 只有 mlflow，无需动 |
> | 厨师（训练客户端） | mlflow-practice:v1（新做） | mlflow 客户端 + sklearn + matplotlib |
>
> 将来算法团队用 pytorch/tensorflow 训练时同理：**训练镜像 = 训练框架 + mlflow 客户端**，
> 换框架换库，MLflow 服务端永远不用动。

真训练需要 `scikit-learn` 和 `matplotlib`，而集群里的 `mlflow:v2.17.2` 镜像没带。
**两条路，选一条**：

### 路线 A（快捷方式）：集群/跳板机有内网 PyPI 源 → 免做镜像

如果公司有内网 pip 源，直接用原镜像起练习 Pod，进去后装库：

```bash
pip install scikit-learn==1.5.2 matplotlib==3.9.2 -i <你们的内网PyPI源地址>
```

装完直接跳到本手册**第二节**。⚠ 注意：这种装法只对当前练习 Pod 生效，下次起 Pod 要重装；
想一劳永逸就走路线 B。

### 路线 B（标准方式）：构建镜像并导入 Harbor

> **完整构建命令、双场景流程与排错表，见同目录《05-Docker镜像打包完整流程.md》。**
> 下面是要点摘要。

**B-1. 在一台有外网的机器上**（有 Docker 即可），把本目录的 `05-Dockerfile.practice`
拷过去，执行：

```bash
docker build -f 05-Dockerfile.practice -t mlflow-practice:v1 .
# 连不上 Harbor 的外网机器，把 Dockerfile 第一行 FROM 改成 ghcr.io/mlflow/mlflow:v2.17.2

docker save -o mlflow-practice-v1.tar mlflow-practice:v1
```

**B-2. 传输并推送到 Harbor**（和你们当初把 mlflow:v2.17.2 导进 Harbor 是同一套流程）：

```bash
# 把 tar 包传到一台能访问 Harbor 的机器后：
docker load -i mlflow-practice-v1.tar
docker tag mlflow-practice:v1 harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1
docker login harbor.ai.cnpc          # 用你们的 Harbor 账号
docker push harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1
```

**B-3. 验证镜像可用**（起个临时 Pod 试一下）：

```bash
kubectl -n ml-platform run practice-check --rm -it --restart=Never \
  --image=harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1 \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"harbor-secret"}]}}' \
  -- python -c "import sklearn, matplotlib, mlflow; print('镜像OK', sklearn.__version__, mlflow.__version__)"
```

> 磁盘提示：这张新镜像 ≈ mlflow 原镜像 + ~60MB，不影响集群；
> 但它存的是**模型文件**的练习数据，都是 KB 级，不会碰你们 50Gi PV 的红线。

---

## 二、第一步：起练习 Pod

```bash
kubectl -n ml-platform run mlflow-real --rm -it --restart=Never \
  --image=harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1 \
  --env=MLFLOW_TRACKING_URI=http://mlflow.ml-platform.svc.cluster.local:5000 \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"harbor-secret"}]}}' \
  -- bash
```

进去后验证连通：

```bash
cd /tmp
curl -s http://mlflow.ml-platform.svc.cluster.local:5000/health   # 应返回 OK
```

---

## 三、第二步：跑真训练（一次脚本走完"训练→记录→注册"闭环）

在 Pod 内 `/tmp` 下整段粘贴：

```bash
cat > 05-train_real.py <<'PYEOF'
import argparse, os
os.environ.setdefault("MPLCONFIGDIR", "/tmp/mplcache")
import mlflow, mlflow.sklearn

TRACKING_URI = os.environ.get("MLFLOW_TRACKING_URI",
                              "http://mlflow.ml-platform.svc.cluster.local:5000")
EXPERIMENT_NAME = "real-model-practice"

parser = argparse.ArgumentParser()
parser.add_argument("--total-trees", type=int, default=150)
parser.add_argument("--depth", type=int, default=6)
parser.add_argument("--steps", type=int, default=5)
args = parser.parse_args()

print(f"[1/6] 连接 MLflow 服务端：{TRACKING_URI}")
mlflow.set_tracking_uri(TRACKING_URI)
mlflow.set_experiment(EXPERIMENT_NAME)

print("[2/6] 加载鸢尾花数据集")
from sklearn.datasets import load_iris
from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, confusion_matrix, ConfusionMatrixDisplay

data = load_iris()
X_train, X_test, y_train, y_test = train_test_split(
    data.data, data.target, test_size=0.2, random_state=42)

print(f"[3/6] 训练（共 {args.total_trees} 棵树，分 {args.steps} 轮，深度 {args.depth}）")
with mlflow.start_run(run_name=f"iris-{args.total_trees}x{args.depth}") as run:
    mlflow.log_params({"total_trees": args.total_trees, "depth": args.depth,
                       "steps": args.steps})
    mlflow.set_tag("owner", os.environ.get("USER", "ops"))
    mlflow.set_tag("model_type", "sklearn-RandomForest")

    per_step = max(1, args.total_trees // args.steps)
    model = RandomForestClassifier(n_estimators=per_step, max_depth=args.depth,
                                   warm_start=True, random_state=42)
    acc = 0
    for step in range(1, args.steps + 1):
        if step > 1:
            model.n_estimators = per_step * step
        model.fit(X_train, y_train)
        acc = accuracy_score(y_test, model.predict(X_test))
        mlflow.log_metric("accuracy", acc, step=step)
        print(f"      第 {step} 轮：{model.n_estimators} 棵树，accuracy={acc:.4f}")
    mlflow.log_metric("final_accuracy", acc)

    print("[4/6] 生成混淆矩阵图并上传")
    disp = ConfusionMatrixDisplay(
        confusion_matrix(y_test, model.predict(X_test)),
        display_labels=data.target_names)
    disp.plot()
    import matplotlib
    matplotlib.pyplot.title("Confusion Matrix")
    matplotlib.pyplot.savefig("confusion_matrix.png", dpi=100)
    mlflow.log_artifact("confusion_matrix.png")

    print("[5/6] 打包模型文件存入 MLflow")
    mlflow.sklearn.log_model(model, "model")

    print("[6/6] 自动注册到 Model Registry：demo-iris-model")
    mv = mlflow.register_model(f"runs:/{run.info.run_id}/model", "demo-iris-model")
    print(f"      已注册为 demo-iris-model Version {mv.version}")

print("\n完成！UI -> real-model-practice 看记录；Models -> demo-iris-model 看注册版本")
PYEOF
python 05-train_real.py
```

正常输出（重点看每轮 accuracy 是**真实计算**出来的、最后的注册成功提示）：

```
[3/6] 训练（共 150 棵树，分 5 轮，深度 6）
      第 1 轮：30 棵树，accuracy=0.9667
      第 2 轮：60 棵树，accuracy=0.9667
      ...
[6/6] 自动注册到 Model Registry：demo-iris-model
      已注册为 demo-iris-model Version 1
```

> 再跑一次 `python 05-train_real.py --total-trees 200 --depth 4`，
> 注册表里会自动出现 Version 2——**版本号就是这么长出来的**，不用人管。

---

## 四、第三步：UI 看真模型长什么样

1. UI → `real-model-practice` 实验 → 点进 run：
   - **Metrics**：真实的 accuracy 曲线（5 个点）
   - **Artifacts** → `model` 文件夹，重点认识这几个文件：

| 文件 | 是什么 |
|---|---|
| `MLmodel` | 模型"说明书"：格式、加载方式、依赖（文本文件，点开看一眼） |
| `model.pkl` | 模型本体（序列化的 sklearn 对象） |
| `requirements.txt` | 运行这个模型需要 pip 装什么 |
| `conda.yaml` / `python_model.env` | 环境说明（你们不用 conda，了解即可） |
| `confusion_matrix.png` | 你上传的图 |

2. 左栏 **Models** → `demo-iris-model` → **Versions** 里已有 Version 1（跑了第二次就有 2）

---

## 五、第四步：把版本切到 Production（真实"发布"动作）

点进 Version 1 → **Stage** 处选择 **Production** → 确认。
这一个动作就是"模型发布"的台账表达：注册表里从此有一个明确的"当前生产版本"。

> **⚠ UI 上显示 `Stage (deprecated)`？** 这是正常现象：MLflow 2.9 起 Stage 被
> **Aliases（别名）** 机制取代，新版注册表 UI 用 **Promote model** 按钮或
> Aliases 处添加 `champion` 别名来表达"生产版本"。两种方式等价，任选其一：
>
> | 方式 | 操作 | 取回 URI |
> |---|---|---|
> | 新方式（推荐） | Version 1 页面 Aliases -> Add -> 输入 `champion`（或点 Promote model） | `models:/demo-iris-model@champion` |
> | 老方式 | 命令行切 Stage，或关掉右上"New model registry UI"开关回到经典界面 | `models:/demo-iris-model/Production` |
>
> 仓库里的 `05-load_real.py` 已升级为**自动兼容两种方式**（先试 champion 别名，再试 Production 阶段）。

> 如果有 Version 2 也切 Production，MLflow 会问要不要把旧 Production 归档
> （Archive existing versions）——这就是"新版本上线、旧版本下线"的机制。

---

## 六、第五步：从注册表取回模型（验证闭环）

在**同一个练习 Pod** 里粘贴：

```bash
cat > 05-load_real.py <<'PYEOF'
import os
os.environ.setdefault("MPLCONFIGDIR", "/tmp/mplcache")
import mlflow, mlflow.sklearn
from sklearn.datasets import load_iris

model_uri = "models:/demo-iris-model/Production"
print(f"[1/3] 加载 {model_uri}")
model = mlflow.sklearn.load_model(model_uri)

print("[2/3] 测试数据（4 特征）")
samples = [[5.1, 3.5, 1.4, 0.2], [6.7, 3.1, 4.7, 1.5]]

print("[3/3] 预测：")
names = load_iris().target_names
for row, p in zip(samples, model.predict(samples)):
    print(f"      {row} -> {names[p]}")
PYEOF
python 05-load_real.py
```

预期输出：

```
      [5.1, 3.5, 1.4, 0.2] -> setosa
      [6.7, 3.1, 4.7, 1.5] -> versicolor
```

**加分项——换个 Pod 也能取**：退出练习 Pod，再起一个全新的一次性 Pod
（同镜像、同 env），粘贴同一份 `05-load_real.py` 执行，照样成功。
这验证了注册表的核心价值：**模型不再散落在某台机器的目录里，任何人凭"模型名+版本"都能取回。**

---

## 七、第六步（进阶）：把模型变成 REST 服务

模型取回来还能"跑起来"。在练习 Pod 里执行：

```bash
mlflow models serve -m models:/demo-iris-model/Production \
  --host 0.0.0.0 -p 8000 --workers 1 > /tmp/serve.log 2>&1 &
sleep 10
curl -s http://127.0.0.1:8000/invocations \
  -H 'Content-Type: application/json' \
  -d '{"inputs": [[5.1, 3.5, 1.4, 0.2], [6.7, 3.1, 4.7, 1.5]]}'
# 预期返回：{"predictions": [0, 1]}
```

看懂这一步你就看懂了"模型上线"的最小形态：
**注册表里的模型 → 进程加载 → 对外提供 HTTP 接口**。
你们的 DeepSeek 大模型走 vLLM 起服务，本质是这个模型的后缀：模型文件 → 推理引擎 → API，
只是引擎换成了专门为大模型优化的 vLLM，并且注册表里用 `storage_path` tag 记录真实路径。

---

## 八、清理

```bash
# 1. UI：real-model-practice 实验 → Delete；Models 页 demo-iris-model → 删除
# 2. 退出 Pod（--rm 自动删）
# 3. 回收文件：
kubectl -n ml-platform exec deploy/mlflow -- \
  mlflow gc --backend-store-uri sqlite:////data/mlflow.db
```

---

## 九、排错表

| 现象 | 原因 | 解决 |
|---|---|---|
| `ImagePullBackOff`（起练习 Pod 时） | 镜像没推上 Harbor / tag 不对 / 漏了 harbor-secret | 核对 `docker push` 输出、tag 拼写、`--overrides` |
| `No module named sklearn` | 用错了镜像（还是原 mlflow 镜像） | 确认 `--image=...mlflow-practice:v1`；或走路线 A 现装 |
| `RESOURCE_ALREADY_EXISTS`（注册时） | 模型名已存在 | 不是错误，会自动登记为新版本 |
| load 报 `404 ... Production` | 该版本还没切 Stage | UI 里切 Production；或临时用 `models:/demo-iris-model/1` |
| serve 起不来 / 端口占用 | 上一次 serve 还在跑 | `pkill -f "mlflow models serve"` 后重试 |
| pip install 失败（路线 A） | 内网源地址不对 | 找运维要正确源；或改走路线 B |
| heredoc 粘贴变形 | 终端截断多行 | 重新完整粘贴，或一行行执行 |

---

## 十、和真实工作的对应关系

| 今天练的 | 真实场景 |
|---|---|
| `05-train_real.py` 全流程 | 算法同事/Jenkins Job 的标准动作：训练→记录→注册一条龙 |
| Stage 切 Production | 模型"发布"动作，可写进你们的变更流程 |
| 换 Pod 取回模型 | 新服务/新环境加载模型的标准方式 |
| `mlflow models serve` | 小模型快速上线的兜底方案；大模型仍走 vLLM |

**至此你的 MLflow 技能闭环**：会看（UI 台账）、会查（run/版本）、会登记（注册表）、
会验（取回预测）、会服务（serve）、会运维（备份/清理/水位/排错）。
