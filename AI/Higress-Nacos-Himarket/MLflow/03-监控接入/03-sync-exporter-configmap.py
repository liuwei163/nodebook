#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把同目录的 03-mlflow-exporter.py 同步进 03-mlflow-exporter-configmap.yaml

用途：根治"源稿与 ConfigMap 内嵌副本两处维护、内容漂移"的问题。
改完源稿后跑一遍本脚本，再 apply ConfigMap + 重启 Pod 即可。

目录约定（2026-11-13 重组后）：源稿、ConfigMap、本脚本同在 03-监控接入/ 下，
不再分放两个旧目录。故用 __file__ 所在目录定位，
从任意工作目录执行都能正确工作。

用法（本机或任意有 python3 的环境）：
    python3 03-监控接入/03-sync-exporter-configmap.py
"""
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE / "03-mlflow-exporter.py"
DST = HERE / "03-mlflow-exporter-configmap.yaml"
# ConfigMap 的 data key 必须与 01-mlflow.yaml 里挂载的文件名一致，勿改
KEY = "  mlflow-exporter.py: |\n"

src_text = SRC.read_text(encoding="utf-8").rstrip("\n")
# ConfigMap 块内整体缩进 4 格；空行不加尾随空格
embedded = KEY + "".join(
    (f"    {line}\n" if line.strip() else "\n")
    for line in src_text.splitlines()
)

dst_text = DST.read_text(encoding="utf-8")
if KEY not in dst_text:
    raise SystemExit(f"ERROR: {DST} 中找不到 key 段 {KEY!r}，请检查文件结构")
head = dst_text.split(KEY)[0]  # data 段之前的部分（注释 + api 段）
# 显式写 LF：内嵌脚本会挂载进 Linux Pod 执行，避免 Windows CRLF 混入
with open(DST, "w", encoding="utf-8", newline="\n") as f:
    f.write(head + embedded)

src_lines = len(src_text.splitlines())
print(f"OK: {SRC.name} ({src_lines} 行) -> {DST.name} 已同步")
