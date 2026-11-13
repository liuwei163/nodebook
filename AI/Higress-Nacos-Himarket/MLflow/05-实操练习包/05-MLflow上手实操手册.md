# MLflow 上手实操手册（纯集群操作版）

> 目标：在 K8s 集群内部完成一次"伪训练"，亲手把训练记录存进 MLflow，
> 并在网页上完成 **记录 → 查看 → 对比 → 注册** 四个动作。全程约 20 分钟。
>
> **本手册的特点**：你的电脑不装 Python、不装 pip、不跑任何代码。
> 练习用的"训练客户端"就是集群里的一个临时 Pod，镜像直接复用集群里已有的
> `harbor.ai.cnpc/ai-platform-poc/mlflow:v2.17.2`，**零新增物料、离线可用**。
>
> 浏览器只负责看 UI（你已能访问）。

---

## 一、物料清单（比本机版短得多）

| # | 物料 | 检查方法 | 缺了怎么办 |
|---|---|---|---|
| 1 | 一个能执行 `kubectl` 的终端（跳板机或你平时管集群的电脑。kubectl 只是遥控器，真正干活的全在集群里） | `kubectl -n ml-platform get pods` 有输出 | 找管理员拿 kubeconfig |
| 2 | 浏览器能打开 MLflow UI | 你已具备 | — |
| 3 | 镜像 `harbor.ai.cnpc/ai-platform-poc/mlflow:v2.17.2` | 集群已有（mlflow 本体就是它） | — |
| 4 | 本手册第四节的 `05-practice.py` 脚本 | 贴进 Pod 即可，无需提前放进集群 | — |

**附带好处**：练习 Pod 用的镜像 = 服务端镜像 = 2.17.2，客户端/服务端版本天然一致，
彻底避开了"版本不匹配"这个最常见的坑。

---

## 二、30 秒搞懂概念（台账思维）

| 概念 | 是什么 | 类比 |
|---|---|---|
| **Experiment（实验）** | 一类任务的文件夹 | 项目目录 |
| **Run** | 一次训练的完整记录 | 一页台账 |
| **Params** | 这次训练用了哪些"旋钮" | 工艺参数 |
| **Metrics** | 效果数值（可多次记录成曲线） | 质检结果 |
| **Artifacts** | 附件：报告、图表、模型文件 | 随台账归档的文件 |
| **Model Registry** | 正式模型台账：名字 + 版本 + 阶段 | 发布清单 |

你的角色定位：**不需要会训练**，但要做到——服务挂了能拉起来、数据丢不了（备份）、
磁盘不爆（水位+清理）、有人问"生产用哪个模型版本"你能秒答（注册表）。

---

## 三、第一步：在集群里起一个练习 Pod（约 1 分钟）

在能执行 kubectl 的终端里运行：

```bash
kubectl -n ml-platform run mlflow-practice --rm -it --restart=Never \
  --image=harbor.ai.cnpc/ai-platform-poc/mlflow:v2.17.2 \
  --env=MLFLOW_TRACKING_URI=http://mlflow.ml-platform.svc.cluster.local:5000 \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"harbor-secret"}]}}' \
  -- bash
```

这条命令逐项解释：

| 片段 | 含义 |
|---|---|
| `run mlflow-practice` | 起一个叫 mlflow-practice 的一次性 Pod |
| `--rm -it --restart=Never` | 交互模式；退出后 Pod 自动删除 |
| `--image=...mlflow:v2.17.2` | 复用集群已有镜像，里面自带 python + mlflow 客户端 |
| `--env=MLFLOW_TRACKING_URI=...` | 告诉客户端往哪发数据（同命名空间的 Service） |
| `--overrides=...harbor-secret...` | 挂上拉私有仓库凭据（你们 Harbor 需要认证，不加会 ImagePullBackOff） |
| `-- bash` | 进 Pod 的 shell |

进去后先验证连通性：

```bash
curl -s http://mlflow.ml-platform.svc.cluster.local:5000/health
# 返回 OK 即通
```

**关键理解**：这个练习 Pod **不挂载任何盘**。它记录的所有数据（参数、指标、附件）
都是通过 HTTP 发给 mlflow 服务端、由服务端写进 NFS 的——这就是你们部署文档里说的
"代理模式"：客户端只需要能连上 server，别的什么都不用管。

---

## 四、第二步：在练习 Pod 里造 3 条训练记录（核心步骤）

在练习 Pod 的 shell 里，先 `cd /tmp`，然后整段粘贴以下内容（一次粘贴整块，回车执行）：

```bash
cd /tmp
cat > 05-practice.py <<'PYEOF'
import argparse, os, random, time
import mlflow

TRACKING_URI = os.environ.get("MLFLOW_TRACKING_URI",
                              "http://mlflow.ml-platform.svc.cluster.local:5000")
EXPERIMENT_NAME = "ops-practice"

parser = argparse.ArgumentParser()
parser.add_argument("--trees", type=int, default=100)
parser.add_argument("--depth", type=int, default=5)
args = parser.parse_args()

print(f"[1/4] 连接 MLflow 服务端：{TRACKING_URI}")
mlflow.set_tracking_uri(TRACKING_URI)
mlflow.set_experiment(EXPERIMENT_NAME)

print(f"[2/4] 开始一条 run（trees={args.trees}, depth={args.depth}）")
with mlflow.start_run(run_name=f"practice-{args.trees}x{args.depth}") as run:
    mlflow.log_params({"trees": args.trees, "depth": args.depth})
    mlflow.set_tag("owner", os.environ.get("USER", "ops"))
    mlflow.set_tag("purpose", "ops-practice")

    print("[3/4] 记录参数 / 指标曲线 / 附件")
    base = 0.80 + args.trees / 1000.0 - abs(args.depth - 6) * 0.02
    acc = base
    for step in range(1, 11):
        acc = min(0.99, base + step * 0.012 + random.uniform(-0.005, 0.005))
        mlflow.log_metric("accuracy", acc, step=step)
        time.sleep(0.2)
    mlflow.log_metric("final_accuracy", acc)

    os.makedirs("reports", exist_ok=True)
    with open("reports/training-report.txt", "w", encoding="utf-8") as f:
        f.write("练习报告\n"
                f"trees={args.trees}, depth={args.depth}\n"
                f"final accuracy={acc:.4f}\n")
    mlflow.log_artifacts("reports", artifact_path="reports")
    run_id = run.info.run_id

print("[4/4] 完成！")
print(f"      run_id         : {run_id}")
print(f"      final accuracy : {acc:.4f}")
print("      打开 MLflow UI -> 左栏 ops-practice 实验查看这条记录")
PYEOF
```

然后跑第一次（用默认参数）：

```bash
python 05-practice.py
```

正常输出：

```
[1/4] 连接 MLflow 服务端：http://mlflow.ml-platform.svc.cluster.local:5000
[2/4] 开始一条 run（trees=100, depth=5）
[3/4] 记录参数 / 指标曲线 / 附件
[4/4] 完成！
      run_id         : 3f2a...
      final accuracy : 0.9821
      打开 MLflow UI -> 左栏 ops-practice 实验查看这条记录
```

> 粘贴后报错多半是终端把多行内容吃掉了——重新完整粘贴一次，或一行一行执行。
> 同名脚本也放在仓库 `05-实操练习包/05-practice.py`，内容一致。

---

## 五、第三步：在网页上看结果（UI 导览，纯点击）

1. 浏览器打开 MLflow UI → 左栏 **Experiments** → 点 **ops-practice**
   （实验是脚本自动创建的，第一次跑完才会出现）
2. 中间表格 = 这个实验下所有 run 的列表：
   - 每行 = 一次训练；`Status`=Finished 表示正常结束
   - `Params` 列能看到 `trees=100`、`depth=5`；`Metrics` 列能看到 `accuracy`
3. 点 run 名称进详情页，从上到下：
   - **Parameters**：这组"旋钮"的值
   - **Metrics**：`accuracy` 有 10 个点连成的折线（脚本模拟了 10 轮训练），
     以及汇总值 `final_accuracy`
   - **Tags**：`owner`（谁跑的）、`purpose`
   - **Artifacts**：`reports/training-report.txt`，点开能预览内容
4. 养成习惯：详情页右上 **Add Description** 写一句备注，三个月后的自己会感谢现在写备注的你。

---

## 六、第四步：练习"对比"（MLflow 的核心价值）

先在 Pod 里再跑两条不同参数的记录：

```bash
python 05-practice.py --trees 50 --depth 3
python 05-practice.py --trees 300 --depth 8
```

回到 UI：

1. ops-practice 实验下现在有 3 个 run
2. 勾选 3 行复选框 → 点 **Compare**
3. 对比页并排展示三组的参数差异、指标曲线
4. 按 `final_accuracy` 从高到低排序——**这就是"选模型"动作的本质**：
   不用翻聊天记录、不用问算法同事，权威数据就在这页表格里

---

## 七、第五步：注册正式台账（纯点击）

1. 打开 `final_accuracy` 最高的 run 详情页
2. 左侧 **Artifacts** 点进 `reports` 文件夹
3. 右上角 **Register Model** → 新建名字 `demo-ops-model` → 确认
4. 左栏 **Models**（注册表）→ 点 `demo-ops-model` → **Version 1** 已出现
5. 点进 Version 1 → 把 **Stage** 设为 **Production** → 在 Description 写"练习注册"

**理解这一步**：MLflow 注册表登记的是"指针 + 台账信息"，不搬运、不校验文件本体——
你们的 65GB 大模型走 `01-register-model.sh` 登记时也是这个原理（source 记路径、
真实 NFS 路径放在 storage_path tag 里）。今天用一个小文件练的是同一套机制。

注册表建成后的价值：Models 页永远能回答三个问题——**有哪些模型？各有哪些版本？
哪个版本在 Production？**这三个问题以后不用问任何人。

---

## 八、第六步：清理

```bash
# 1. 退出练习 Pod（--rm 会自动删掉它），如果窗口被强关了，手动删：
kubectl -n ml-platform delete pod mlflow-practice --ignore-not-found

# 2. UI 里：ops-practice 右侧菜单 → Delete Experiment（练习数据可删）

# 3. 彻底回收文件（UI 删除只是软删除，这是运维的回收动作）：
kubectl -n ml-platform exec deploy/mlflow -- \
  mlflow gc --backend-store-uri sqlite:////data/mlflow.db
```

---

## 九、排错表（集群版）

| 现象 | 原因 | 解决 |
|---|---|---|
| Pod 卡在 `ImagePullBackOff` | 漏了 `--overrides` 里的 harbor-secret，或镜像 tag 写错 | 补上 overrides；确认 tag 是 `v2.17.2` |
| Pod 里 `curl` 无响应 | DNS/Service 异常 | `kubectl -n ml-platform get svc mlflow` 确认 Service 在、端口 5000 |
| `python 05-practice.py` 连接超时 | 练习 Pod 不在 ml-platform 命名空间 | 检查 `kubectl run` 命令里的 `-n ml-platform` |
| heredoc 粘贴后 `python: can't open file` | 多行粘贴被终端截断 | 重新完整粘贴，或改为一行一行执行 |
| `409 Experiment already exists` | 实验已存在 | 不是错误，忽略 |
| `database is locked` | 出现了多写者 | 立即确认 mlflow Deployment 是 1 副本（你们配置本就是），仍复现则记录时间点排查 |
| UI 打不开 run 详情 | 服务端 Pod 重启过 | `kubectl -n ml-platform get pods` 看状态与重启次数 |

---

## 十、练完之后：真实工作怎么对应

| 今天练的 | 真实工作 |
|---|---|
| 临时 Pod 里记录 params/metrics | 算法同事/Jenkins 训练 Job 里的真实动作；你保证服务端健康、入口可达 |
| UI 对比选 run | 评审会上"哪版更好"的权威依据 |
| Register Model + Production | 模型台账；对应你已跑通的 `01-register-model.sh` 大模型登记 |
| `mlflow gc` / 删实验 | 例行运维：定期备份 mlflow.db、盯 `/data` 水位、清理废弃 run |

**进阶（可选）**：想练"真模型"（真训练、真模型文件、log_model / load_model / 模型服务），
看同目录的 **`05-MLflow真模型实操手册.md`**——含练习镜像制作/导入 Harbor、真训练脚本、
注册表取回验证、REST 服务化六步。练台账管理的话，本手册的纯客户端练习已经足够。
