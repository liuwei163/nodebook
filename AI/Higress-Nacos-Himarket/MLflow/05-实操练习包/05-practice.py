# -*- coding: utf-8 -*-
"""
MLflow 集群内练习脚本（纯 MLflow 客户端，不需要 sklearn、不需要懂算法）
=======================================================================
运行环境：集群里的临时练习 Pod（镜像 harbor.ai.cnpc/ai-platform-poc/mlflow:v2.17.2）
用法（在 Pod 内）：
    python 05-practice.py                       # 默认参数跑第一次
    python 05-practice.py --trees 50 --depth 3  # 换参数再跑，用于对比练习
    python 05-practice.py --trees 300 --depth 8
"""
import argparse
import os
import random
import time

import mlflow

# 服务端地址：同命名空间内的 Service（也可用环境变量 MLFLOW_TRACKING_URI 覆盖）
TRACKING_URI = os.environ.get(
    "MLFLOW_TRACKING_URI", "http://mlflow.ml-platform.svc.cluster.local:5000"
)
EXPERIMENT_NAME = "ops-practice"

# 两个"旋钮"参数。不懂算法没关系，就当是两颗调节效果的旋钮
parser = argparse.ArgumentParser(description="MLflow 集群内练习")
parser.add_argument("--trees", type=int, default=100, help="旋钮一：树的数量")
parser.add_argument("--depth", type=int, default=5, help="旋钮二：树的深度")
args = parser.parse_args()

print(f"[1/4] 连接 MLflow 服务端：{TRACKING_URI}")
mlflow.set_tracking_uri(TRACKING_URI)

# 实验不存在会自动创建（相当于新建一个文件夹放训练记录）
mlflow.set_experiment(EXPERIMENT_NAME)

print(f"[2/4] 开始一条 run（trees={args.trees}, depth={args.depth}）")
# start_run 到 with 结束之间记录的所有内容，都归属这一个 run
with mlflow.start_run(run_name=f"practice-{args.trees}x{args.depth}") as run:
    # 记录"用了什么参数"——三个月后还能查到这组效果对应哪组旋钮
    mlflow.log_params({"trees": args.trees, "depth": args.depth})
    # 标签：留名 + 标用途
    mlflow.set_tag("owner", os.environ.get("USER", "ops"))
    mlflow.set_tag("purpose", "ops-practice")

    # 模拟一条训练曲线：每一"轮"记录一次 accuracy，UI 上会画出折线图
    print("[3/4] 记录参数 / 指标曲线 / 附件")
    base = 0.80 + args.trees / 1000.0 - abs(args.depth - 6) * 0.02
    acc = base
    for step in range(1, 11):
        acc = min(0.99, base + step * 0.012 + random.uniform(-0.005, 0.005))
        mlflow.log_metric("accuracy", acc, step=step)
        time.sleep(0.2)
    mlflow.log_metric("final_accuracy", acc)

    # 造一个附件文件传上去（练习 log_artifacts；真实场景里放训练报告、图表）
    os.makedirs("reports", exist_ok=True)
    with open("reports/training-report.txt", "w", encoding="utf-8") as f:
        f.write(
            "练习报告\n"
            f"trees={args.trees}, depth={args.depth}\n"
            f"final accuracy={acc:.4f}\n"
        )
    mlflow.log_artifacts("reports", artifact_path="reports")

    run_id = run.info.run_id

print("[4/4] 完成！")
print(f"      run_id         : {run_id}")
print(f"      final accuracy : {acc:.4f}")
print("      打开 MLflow UI -> 左栏 ops-practice 实验查看这条记录")
