#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
离线 LLM 推理压测脚本（纯 Python 标准库，无需 pip install 任何东西）

为什么不用 vllm bench：
  离线环境装不了客户端依赖，且 hop 到 router 的机器可能连 python 环境都没有。
  这个脚本只用 http.client + threading，任何 python3 都能跑。

用法：
  1) 打通 router（在能 kubectl 的机器上开个端口转发，保持前台）
     kubectl -n kthena-system port-forward svc/kthena-router 8080:80

  2) 另开一个终端跑压测
     python3 04-npu_bench.py --base-url http://127.0.0.1:8080 \
         --model DeepSeek-R1-Distill-Qwen-32B \
         --scenario long-in --concurrency 1,4,8,16 \
         --num-requests 32 --out result-pd-long.json

  3) 换一个场景再跑一次，两次的 json 就是 PD 对比实验的原始数据
     python3 04-npu_bench.py ... --scenario short-in --out result-pd-short.json
"""

import argparse
import http.client
import json
import random
import statistics
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor


# ---------------- 两个场景，对应 PD 对比实验的 2x2 矩阵 ----------------
FILLER = (
    "Kubernetes 集群中的节点状态异常，kubelet 持续上报 NotReady，"
    "容器运行时返回 context deadline exceeded，调度器将该节点标记为不可调度，"
    "部分 Pod 被驱逐并在其他节点重建，服务出现短暂抖动，需要确认 etcd 健康状态与网络连通性。"
)

SCENARIOS = {
    # 长输入短输出：prefill 主导，PD 分离收益最大
    "long-in": {
        "prompt": "请阅读以下运维日志，用一句话概括根因：" + FILLER * 40,
        "max_tokens": 32,
    },
    # 短输入长输出：decode 主导，PD 分离往往没有收益甚至变差
    # 注意 max_tokens 别设太大：TPOT 150ms 的话 512 token 单请求就要 74 秒，整个矩阵要跑一小时
    "short-in": {
        "prompt": "用大约 400 字说明 Kubernetes Pod 一直 Pending 的排查思路。",
        "max_tokens": 128,
    },
}

_results_lock = threading.Lock()

_NONCE_CHARS = "甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉"


def make_prompt(scenario, idx, cache_bust):
    """cache_bust=True 时在 prompt 最前面加随机串。

    prefix cache 是按前缀匹配的，所以随机内容必须放在最前面，
    否则前面几千字仍然命中缓存，等于没打散。
    """
    base = SCENARIOS[scenario]["prompt"]
    if not cache_bust:
        return base
    nonce = "".join(random.choice(_NONCE_CHARS) for _ in range(48))
    return "工单编号 %s 的第 %d 次咨询：" % (nonce, idx) + base


def parse_base_url(base_url):
    u = urllib.parse.urlparse(base_url)
    host = u.hostname or "127.0.0.1"
    port = u.port or (443 if u.scheme == "https" else 80)
    return host, port, u.scheme == "https"


def chat_once(base_url, model, prompt, max_tokens, timeout=300):
    """发一次流式请求，返回 (ttft, tpot, e2e, out_tokens) 或抛异常。"""
    host, port, use_tls = parse_base_url(base_url)
    conn_cls = http.client.HTTPSConnection if use_tls else http.client.HTTPConnection
    conn = conn_cls(host, port, timeout=timeout)

    payload = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0.0,
            "stream": True,
            "stream_options": {"include_usage": True},
        },
        ensure_ascii=False,
    ).encode("utf-8")

    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "Connection": "close",
    }

    start = time.perf_counter()
    try:
        conn.request("POST", "/v1/chat/completions", payload, headers)
        resp = conn.getresponse()
        if resp.status != 200:
            raise RuntimeError("HTTP %s: %s" % (resp.status, resp.read()[:300]))

        ttft = None
        chunks = 0
        completion_tokens = None

        for raw in resp:
            line = raw.decode("utf-8", "ignore").strip()
            if not line or not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
            except ValueError:
                continue
            if obj.get("usage"):
                completion_tokens = obj["usage"].get("completion_tokens") or completion_tokens
            for ch in obj.get("choices") or []:
                delta = ch.get("delta") or {}
                piece = delta.get("content") or delta.get("reasoning_content")
                if piece:
                    if ttft is None:
                        ttft = time.perf_counter() - start
                    chunks += 1
        # 读到 EOF 再关闭：提前 close 会让服务端写不进去，port-forward 日志刷
        # "error copying from local connection to remote stream: read: connection reset by peer"
        try:
            resp.read()
        except Exception:  # noqa: BLE001
            pass

        end = time.perf_counter()
    finally:
        conn.close()

    if ttft is None:
        raise RuntimeError("没有收到任何 token")

    out_tokens = completion_tokens or chunks
    decode_time = max(end - start - ttft, 1e-6)
    tpot = decode_time / max(out_tokens - 1, 1)
    return ttft, tpot, end - start, out_tokens


def pct(values, p):
    if not values:
        return float("nan")
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]


def run_level(base_url, model, scenario, concurrency, num_requests,
              max_tokens_override=None, cache_bust=True):
    cfg = SCENARIOS[scenario]
    max_tokens = max_tokens_override or cfg["max_tokens"]

    samples = []
    errors = []

    def task(i):
        try:
            prompt = make_prompt(scenario, i, cache_bust)
            r = chat_once(base_url, model, prompt, max_tokens)
            with _results_lock:
                samples.append(r)
        except Exception as e:  # noqa: BLE001
            with _results_lock:
                errors.append(str(e))

    wall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        list(pool.map(task, range(num_requests)))
    wall = time.perf_counter() - wall_start

    if not samples:
        return {
            "concurrency": concurrency,
            "ok": 0,
            "errors": len(errors),
            "sample_error": errors[:1],
        }

    ttfts = [s[0] for s in samples]
    tpots = [s[1] for s in samples]
    e2es = [s[2] for s in samples]
    out_tok = sum(s[3] for s in samples)

    return {
        "concurrency": concurrency,
        "ok": len(samples),
        "errors": len(errors),
        "ttft_p50_ms": round(pct(ttfts, 50) * 1000, 1),
        "ttft_p99_ms": round(pct(ttfts, 99) * 1000, 1),
        "tpot_ms": round(statistics.mean(tpots) * 1000, 2),
        "e2e_p50_ms": round(pct(e2es, 50) * 1000, 1),
        "output_tokens": out_tok,
        "wall_s": round(wall, 2),
        "output_tok_per_s": round(out_tok / wall, 2),
        "req_per_s": round(len(samples) / wall, 3),
        "output_tokens_per_req": round(out_tok / len(samples), 1),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True, help="如 http://127.0.0.1:8080")
    ap.add_argument("--model", required=True, help="请求里的 model 字段")
    ap.add_argument("--scenario", default="long-in", choices=sorted(SCENARIOS))
    ap.add_argument("--concurrency", default="1,4,8,16", help="逗号分隔的并发梯度")
    ap.add_argument("--num-requests", type=int, default=32)
    ap.add_argument("--max-tokens", type=int, default=None,
                    help="覆盖场景默认的 max_tokens，decode 慢的时候一定要调小")
    ap.add_argument("--no-cache-bust", action="store_true",
                    help="所有请求用完全相同的 prompt（会命中 prefix cache，TTFT 偏低，仅用于量化缓存收益）")
    ap.add_argument("--out", default="result.json")
    args = ap.parse_args()

    levels = [int(x) for x in args.concurrency.split(",") if x.strip()]
    mt = args.max_tokens or SCENARIOS[args.scenario]["max_tokens"]
    cache_bust = not args.no_cache_bust

    if args.num_requests < max(levels):
        print("!! 警告：num_requests=%d 小于最大并发 %d，实际并发会被请求总数卡住，"
              "这一档等价于 %d 并发。想看真实 %d 并发，把 --num-requests 提到 %d 以上。"
              % (args.num_requests, max(levels), args.num_requests,
                 max(levels), max(levels) * 2))
    assume_tpot = 0.15  # 粗略预估用，跑完以实测为准
    est_min = sum(args.num_requests / float(c) * mt * assume_tpot for c in levels) / 60.0
    print("scenario=%s  输入约 %d 字  max_tokens=%d  num_requests=%d  cache_bust=%s"
          % (args.scenario, len(SCENARIOS[args.scenario]["prompt"]), mt,
             args.num_requests, "on" if cache_bust else "OFF(会命中缓存)"))
    if est_min > 5:
        print("预估总耗时约 %.0f 分钟（按 TPOT=150ms 粗估）。太久就调小 --max-tokens 或 --num-requests"
              % est_min)
    all_rows = []

    print("%-6s %-7s %-10s %-10s %-9s %-9s %-9s" %
          ("conc", "ok/err", "TTFT_p50", "TTFT_p99", "TPOT", "tok/s", "req/s"))
    print("-" * 68)

    for c in levels:
        row = run_level(args.base_url, args.model, args.scenario, c,
                        args.num_requests, mt, cache_bust)
        all_rows.append(row)
        if row["ok"]:
            print("%-6d %-7s %-10s %-10s %-9s %-9s %-9s" % (
                row["concurrency"],
                "%d/%d" % (row["ok"], row["errors"]),
                "%.0fms" % row["ttft_p50_ms"],
                "%.0fms" % row["ttft_p99_ms"],
                "%.1fms" % row["tpot_ms"],
                "%.1f" % row["output_tok_per_s"],
                "%.2f" % row["req_per_s"],
            ))
        else:
            print("%-6d 全部失败: %s" % (row["concurrency"], row.get("sample_error")))
            print("       -> 先确认 port-forward 还在、model 名字对、router 后端的 ModelServer 选中了 Pod")

    out = {
        "meta": {
            "base_url": args.base_url,
            "model": args.model,
            "scenario": args.scenario,
            "num_requests": args.num_requests,
            "concurrency_levels": levels,
            "max_tokens": mt,
            "cache_bust": cache_bust,
            "temperature": 0.0,
            "stream": True,
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        },
        "rows": all_rows,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("\n已写入 %s" % args.out)


if __name__ == "__main__":
    sys.exit(main())
