# -*- coding: utf-8 -*-
"""
MLflow 真模型练习：从注册表取回模型并做预测
============================================
兼容两种"生产版本"标记方式（新版 UI 用别名，旧版用 Stage）：
  - 新方式（推荐）：别名 champion -> models:/demo-iris-model@champion
  - 老方式：Stage Production -> models:/demo-iris-model/Production
用法（本地 Windows，MLFLOW_TRACKING_URI 已指向服务端域名）：
    py -3.11 05-load_real.py
    py -3.11 05-load_real.py --uri "models:/demo-iris-model/1"   # 直接指定版本号
"""
import argparse
import os

os.environ.setdefault("MPLCONFIGDIR", "/tmp/mplcache")

import mlflow
import mlflow.sklearn
from sklearn.datasets import load_iris

parser = argparse.ArgumentParser(description="从 MLflow 注册表取回模型")
parser.add_argument(
    "--uri", default=None,
    help='模型 URI；不填则自动依次尝试 champion 别名和 Production 阶段',
)
args = parser.parse_args()

CANDIDATES = [
    "models:/demo-iris-model@champion",     # 新方式：别名（MLflow 2.9+，新注册表 UI 用这个）
    "models:/demo-iris-model/Production",   # 老方式：Stage（页面标注 deprecated，但仍可用）
]

print("[1/3] 从 MLflow 注册表加载模型")
candidates = [args.uri] if args.uri else CANDIDATES

model = None
model_uri = None
for uri in candidates:
    try:
        print(f"      尝试 {uri} ...")
        model = mlflow.sklearn.load_model(uri)
        model_uri = uri
        break
    except Exception as e:
        print(f"      不可用（{type(e).__name__}: {str(e)[:60]}）")

if model is None:
    print("\n所有候选都不可用。请二选一：")
    print("  a) UI 里给 Version 1 添加别名 champion（Aliases -> Add -> 输入 champion）")
    print('  b) 命令行切 Stage（整行复制执行）：')
    print('     py -3.11 -c "from mlflow.tracking import MlflowClient; MlflowClient().transition_model_version_stage(name=\'demo-iris-model\', version=\'1\', stage=\'Production\')"')
    raise SystemExit(1)
print(f"      加载成功：{model_uri}")

print("[2/3] 测试数据（4 特征：花萼长宽、花瓣长宽）")
samples = [[5.1, 3.5, 1.4, 0.2], [6.7, 3.1, 4.7, 1.5]]

print("[3/3] 预测结果：")
names = load_iris().target_names
preds = model.predict(samples)
for row, p in zip(samples, preds):
    print(f"      {row}  ->  {names[p]}")

print("\n含义：任何人、任何机器，凭模型名+版本（或别名）都能取回模型——")
print("     模型不再散落在某台机器的某个目录里。")
