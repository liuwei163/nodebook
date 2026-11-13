#!/bin/sh
# mini-mcp 端点自测脚本（在节点本机执行，也可以用别的机器测）
# 用法:
#   sh test-mini-mcp.sh                    # 默认测 http://127.0.0.1:8765
#   sh test-mini-mcp.sh <JUMPHOST_IP>:8765   # 测远端节点
BASE="${1:-127.0.0.1:8765}"
BASE="http://${BASE#http://}"
URL="${BASE}/mcp"

echo "== 1. 健康检查  GET ${BASE}/"
curl -sS -m 5 "${BASE}/" || echo "[失败] 端口没起来或被防火墙拦了"
echo ""

echo "== 2. initialize"
curl -sS -m 5 -X POST "$URL" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
echo ""

echo "== 3. notifications/initialized（期望 202，无 body）"
curl -sS -m 5 -o /dev/null -w 'http_code=%{http_code}\n' -X POST "$URL" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo "== 4. tools/list（期望看到 get_time / echo / add）"
curl -sS -m 5 -X POST "$URL" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
echo ""

echo "== 5. tools/call get_time"
curl -sS -m 5 -X POST "$URL" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_time","arguments":{"timezone":"Asia/Shanghai"}}}'
echo ""

echo "== 6. tools/call echo"
curl -sS -m 5 -X POST "$URL" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello mcp"}}}'
echo ""

echo "== 7. GET /mcp（期望 405，符合规范）"
curl -sS -m 5 -o /dev/null -w 'http_code=%{http_code}\n' "$URL"

echo "== 完成 =="
