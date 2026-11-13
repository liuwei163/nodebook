# -*- coding: utf-8 -*-
"""
MLflow 真模型练习：鸢尾花分类（真实训练 + 真实模型文件 + 训练完自动注册）
=========================================================================
运行环境：集群练习 Pod（镜像 harbor.ai.cnpc/ai-platform-poc/mlflow-practice:v1）
真在哪里：
  1. 数据是真的鸢尾花数据集（sklearn 自带，无需下载）
  2. 训练是真的（每轮真的往森林里加一批树，accuracy 是真实算出来的）
  3. 模型文件是真的会打包进 MLflow artifact 存储（能被 load 回来）
  4. 训练结束自动注册进 Model Registry（"训练即注册"闭环）
用法（在 Pod 内 /tmp 下）：
    python 05-train_real.py                       # 默认参数
    python 05-train_real.py --total-trees 200 --depth 4   # 换参数对比
"""
import argparse
import os

os.environ.setdefault("MPLCONFIGDIR", "/tmp/mplcache")  # matplotlib 缓存目录

import mlflow
import mlflow.sklearn

TRACKING_URI = os.environ.get(
    "MLFLOW_TRACKING_URI", "http://mlflow.ml-platform.svc.cluster.local:5000"
)
EXPERIMENT_NAME = "real-model-practice"

parser = argparse.ArgumentParser(description="MLflow 真模型练习：鸢尾花分类")
parser.add_argument("--total-trees", type=int, default=150, help="森林最终树的数量")
parser.add_argument("--depth", type=int, default=6, help="每棵树最大深度")
parser.add_argument("--steps", type=int, default=5, help="分几轮训练（用于画曲线）")
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
    data.data, data.target, test_size=0.2, random_state=42
)

print(f"[3/6] 训练（共 {args.total_trees} 棵树，分 {args.steps} 轮，深度 {args.depth}）")
with mlflow.start_run(run_name=f"iris-{args.total_trees}x{args.depth}") as run:
    mlflow.log_params(
        {"total_trees": args.total_trees, "depth": args.depth, "steps": args.steps}
    )
    mlflow.set_tag("owner", os.environ.get("USER", "ops"))
    mlflow.set_tag("model_type", "sklearn-RandomForest")

    # warm_start=True：每轮在已有森林上"追加"一批树，accuracy 随树增多真实变化
    per_step = max(1, args.total_trees // args.steps)
    model = RandomForestClassifier(
        n_estimators=per_step, max_depth=args.depth,
        warm_start=True, random_state=42,
    )
    for step in range(1, args.steps + 1):
        if step > 1:
            model.n_estimators = per_step * step  # 追加树的数量
        model.fit(X_train, y_train)
        acc = accuracy_score(y_test, model.predict(X_test))
        mlflow.log_metric("accuracy", acc, step=step)
        print(f"      第 {step} 轮：{model.n_estimators} 棵树，accuracy={acc:.4f}")
    mlflow.log_metric("final_accuracy", acc)

    print("[4/6] 生成混淆矩阵图并上传")
    disp = ConfusionMatrixDisplay(
        confusion_matrix(y_test, model.predict(X_test)),
        display_labels=data.target_names,
    )
    disp.plot()
    import matplotlib
    matplotlib.pyplot.title("Confusion Matrix")
    matplotlib.pyplot.savefig("confusion_matrix.png", dpi=100)
    mlflow.log_artifact("confusion_matrix.png")

    print("[5/6] 打包模型文件存入 MLflow（artifact 存储）")
    mlflow.sklearn.log_model(model, "model")

    # 训练即注册：把刚存的模型自动登记进 Model Registry
    print("[6/6] 自动注册到 Model Registry：demo-iris-model")
    mv = mlflow.register_model(f"runs:/{run.info.run_id}/model", "demo-iris-model")
    print(f"      已注册为 demo-iris-model Version {mv.version}（当前 stage 为 None）")

print("\n完成！接下来：")
print(f"  1. UI -> real-model-practice 实验看本条 run（run_id={run.info.run_id}）")
print(f"  2. UI -> Models -> demo-iris-model -> Version {mv.version}")
print("     手动把 Stage 切到 Production（真实'发布'动作）")
print("  3. 用 05-load_real.py 从注册表把模型取回验证")
