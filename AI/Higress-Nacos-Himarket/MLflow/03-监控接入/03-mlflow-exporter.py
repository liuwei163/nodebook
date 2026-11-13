#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MLflow 监控导出器（纯 Python 标准库实现，零第三方依赖，离线环境可用）
=====================================================================
背景：MLflow server 自身不提供 Prometheus /metrics 接口，所以需要在
Pod 里加一个 sidecar 导出器，把平台指标翻译成 Prometheus 文本格式。

采集的指标（13 个，按四黄金信号归类）：
  mlflow_up                              服务健康（GET /health，1=正常 0=挂）
  mlflow_health_probe_duration_seconds   探活请求耗时（延迟信号，秒）
  mlflow_disk_used_bytes                 /data 已用字节（NFS PV）
  mlflow_disk_total_bytes                /data 总容量字节
  mlflow_disk_used_ratio                 /data 使用率（0~1，对接水位告警）
  mlflow_experiments_total               活跃实验总数
  mlflow_runs_total                      活跃 run 总数
  mlflow_runs_by_status                  按 status 细分的 run 数（流量/错误信号）
  mlflow_run_duration_seconds_avg        已结束 run 的平均训练时长（秒）
  mlflow_registered_models_total         注册模型总数
  mlflow_model_versions_total            模型版本总数
  mlflow_model_versions_created_24h      最近 24h 新增模型版本数（登记流量）

四黄金信号对照：
  错误   <- mlflow_up + mlflow_runs_by_status{status="FAILED"}
  延迟   <- mlflow_health_probe_duration_seconds（合成探针）
  流量   <- mlflow_runs_total 增速 / mlflow_model_versions_created_24h
  饱和度 <- mlflow_disk_used_ratio

设计要点：
  - sqlite 用只读模式（file:...?mode=ro）查询，不干扰服务端单写者
  - 磁盘用 statvfs 直接量 /data，与巡检脚本、备份看到的数字同源
  - run 状态/时长/版本登记时间全部从 sqlite 推导——库本身就是事件账本

部署：作为 mlflow Pod 的 sidecar 容器，与主容器共享 /data 挂载。
采集间隔默认 15 秒，可用环境变量 COLLECT_INTERVAL 调整。
注意：修改本脚本后需运行 03-监控接入/03-sync-exporter-configmap.py 同步进
ConfigMap，再重启 Pod 生效（挂载文件自动更新，但进程不会重载）。
"""
import http.server
import os
import sqlite3
import threading
import time
import urllib.request

TRACKING = os.environ.get("MLFLOW_TRACKING_URI", "http://127.0.0.1:5000")
DATA_DIR = os.environ.get("MLFLOW_DATA_DIR", "/data")
DB_PATH = os.environ.get("MLFLOW_DB_PATH", "/data/mlflow.db")
PORT = int(os.environ.get("EXPORTER_PORT", "9110"))
INTERVAL = int(os.environ.get("COLLECT_INTERVAL", "15"))

_lock = threading.Lock()
_cache = {"text": "# exporter starting\n"}


def health_probe():
    """探测主容器 /health，2 秒超时。返回 (up, 耗时秒)"""
    start = time.monotonic()
    try:
        with urllib.request.urlopen(TRACKING + "/health", timeout=2) as r:
            up = 1 if r.status == 200 else 0
    except Exception:
        up = 0
    return up, time.monotonic() - start


def disk_metrics(lines):
    """磁盘用量：statvfs 直接量 /data（NFS PV），不需要额外组件"""
    st = os.statvfs(DATA_DIR)
    total = st.f_blocks * st.f_frsize
    free = st.f_bfree * st.f_frsize
    used = total - free
    ratio = used / total if total else 0.0
    lines += [
        "# HELP mlflow_disk_used_bytes Data dir used bytes",
        "# TYPE mlflow_disk_used_bytes gauge",
        f"mlflow_disk_used_bytes {used}",
        "# HELP mlflow_disk_total_bytes Data dir total bytes",
        "# TYPE mlflow_disk_total_bytes gauge",
        f"mlflow_disk_total_bytes {total}",
        "# HELP mlflow_disk_used_ratio Data dir usage ratio 0-1",
        "# TYPE mlflow_disk_used_ratio gauge",
        f"mlflow_disk_used_ratio {ratio:.6f}",
    ]


def db_counts():
    """业务计数：只读模式查 sqlite，避免干扰服务端写入"""
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=5)
    try:
        cur = conn.cursor()
        exp = cur.execute(
            "SELECT COUNT(*) FROM experiments WHERE lifecycle_stage='active'"
        ).fetchone()[0]
        runs = cur.execute(
            "SELECT COUNT(*) FROM runs WHERE lifecycle_stage='active'"
        ).fetchone()[0]
        models = cur.execute("SELECT COUNT(*) FROM registered_models").fetchone()[0]
        versions = cur.execute("SELECT COUNT(*) FROM model_versions").fetchone()[0]
        return exp, runs, models, versions
    finally:
        conn.close()


def db_business(lines):
    """从 sqlite 推导流量/错误/业务信号（run 状态分布、训练时长、登记频率）"""
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=5)
    try:
        cur = conn.cursor()

        # run 状态分布（错误信号：FAILED 占比；流量信号：RUNNING 是当前负载）
        rows = cur.execute(
            "SELECT status, COUNT(*) FROM runs "
            "WHERE lifecycle_stage='active' GROUP BY status"
        ).fetchall()
        by_status = {s: c for s, c in rows}
        lines.append("# HELP mlflow_runs_by_status Active runs by status")
        lines.append("# TYPE mlflow_runs_by_status gauge")
        for status in ("RUNNING", "SCHEDULED", "FINISHED", "FAILED", "KILLED"):
            lines.append(f'mlflow_runs_by_status{{status="{status}"}} '
                         f"{by_status.get(status, 0)}")

        # 平均训练时长（秒）：end_time - start_time（毫秒时间戳）
        avg_dur = cur.execute(
            "SELECT AVG(end_time - start_time) / 1000.0 FROM runs "
            "WHERE lifecycle_stage='active' AND end_time IS NOT NULL "
            "AND end_time >= start_time"
        ).fetchone()[0] or 0.0
        lines.append(
            "# HELP mlflow_run_duration_seconds_avg "
            "Average duration of finished runs in seconds")
        lines.append("# TYPE mlflow_run_duration_seconds_avg gauge")
        lines.append(f"mlflow_run_duration_seconds_avg {avg_dur:.1f}")

        # 最近 24h 新增模型版本数（登记频率 = 使用流量信号）
        cutoff_ms = int(time.time() * 1000) - 24 * 3600 * 1000
        v24 = cur.execute(
            "SELECT COUNT(*) FROM model_versions WHERE creation_timestamp >= ?",
            (cutoff_ms,),
        ).fetchone()[0]
        lines.append(
            "# HELP mlflow_model_versions_created_24h "
            "Model versions created in the last 24 hours")
        lines.append("# TYPE mlflow_model_versions_created_24h gauge")
        lines.append(f"mlflow_model_versions_created_24h {v24}")
    finally:
        conn.close()


def count_metrics(lines, exp, runs, models, versions):
    pairs = [
        ("mlflow_experiments_total", exp, "Total active experiments"),
        ("mlflow_runs_total", runs, "Total active runs"),
        ("mlflow_registered_models_total", models, "Total registered models"),
        ("mlflow_model_versions_total", versions, "Total model versions"),
    ]
    for name, val, help_text in pairs:
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} gauge")
        lines.append(f"{name} {val}")


def collect():
    lines = []
    up, probe_dur = health_probe()
    lines.append("# HELP mlflow_up MLflow server health 1=up 0=down")
    lines.append("# TYPE mlflow_up gauge")
    lines.append(f"mlflow_up {up}")
    lines.append(
        "# HELP mlflow_health_probe_duration_seconds "
        "Duration of the /health probe in seconds")
    lines.append("# TYPE mlflow_health_probe_duration_seconds gauge")
    lines.append(f"mlflow_health_probe_duration_seconds {probe_dur:.4f}")
    try:
        disk_metrics(lines)
    except Exception:
        pass  # 挂载异常时跳过磁盘指标，其余照常
    try:
        exp, runs, models, versions = db_counts()
        count_metrics(lines, exp, runs, models, versions)
    except Exception as e:
        lines.append(f"# mlflow_db_read_error {type(e).__name__}")
    try:
        db_business(lines)
    except Exception as e:
        lines.append(f"# mlflow_db_business_error {type(e).__name__}")
    text = "\n".join(lines) + "\n"
    with _lock:
        _cache["text"] = text


def loop():
    while True:
        try:
            collect()
        except Exception:
            pass
        time.sleep(INTERVAL)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            with _lock:
                body = _cache["text"].encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"mlflow exporter, see /metrics\n")

    def log_message(self, *args):
        pass  # 静默访问日志，避免刷屏


if __name__ == "__main__":
    threading.Thread(target=loop, daemon=True).start()
    with http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler) as httpd:
        httpd.serve_forever()
