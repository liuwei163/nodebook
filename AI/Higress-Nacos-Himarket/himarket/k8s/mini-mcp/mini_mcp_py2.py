#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mini-mcp  —— 零依赖、Python 2.7 / Python 3 双兼容的最小 MCP Server
            传输方式：Streamable HTTP（JSON-RPC 2.0 over HTTP POST）

为什么有这个版本：
    生产节点上只有 python 2.7.8，没有 python3，也无法 pip install。
    本文件只用 Python 标准库（BaseHTTPServer / json / datetime），
    不需要 mcp / fastmcp 任何第三方包，拷贝即用。

用法：
    python  mini_mcp_py2.py            # 默认监听 0.0.0.0:8765
    python  mini_mcp_py2.py 9000       # 指定端口
    python3 mini_mcp_py2.py 8765       # py3 也能跑，同一份文件

端点（两种传输同时支持）：
    方式 A  Streamable HTTP（推荐，MCP 2025 规范）
        POST /mcp     JSON-RPC 入口，注册时填 http://<IP>:8765/mcp
   方式 B  旧式 SSE（万一 HiMarket 只给 SSE 选项时用）
        GET  /sse     建立事件流，注册时填 http://<IP>:8765/sse
        POST /message?sessionId=xxx   客户端回调入口（自动处理）
    辅助
        GET  /        健康检查（浏览器/curl 直接看）
        GET  /mcp     405（本服务不主动推送，符合规范）

提供的工具：
    get_time(timezone)   取当前时间
    echo(text)           原样回显
    add(a, b)            两数相加
"""

import json
import sys
import time
import uuid
import datetime
import threading

# ---- py2 / py3 兼容导入 ----
try:  # Python 2
    from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer
    from SocketServer import ThreadingMixIn
    from urlparse import urlparse, parse_qs
    text_type = unicode  # noqa: F821
except ImportError:  # Python 3
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from socketserver import ThreadingMixIn
    from urllib.parse import urlparse, parse_qs
    text_type = str

SERVER_NAME = "mini-mcp"
SERVER_VERSION = "1.1.0"
FALLBACK_PROTOCOL = "2024-11-05"   # 客户端没报版本时用这个

# 只做固定偏移，不引入 pytz；键统一小写
TZ_OFFSETS = {
    "asia/shanghai": 8, "prc": 8, "asia/chongqing": 8, "asia/hong_kong": 8,
    "asia/taipei": 8, "asia/singapore": 8, "asia/tokyo": 9, "asia/seoul": 9,
    "utc": 0, "gmt": 0, "etc/utc": 0, "europe/london": 0,
    "asia/dubai": 4, "asia/kolkata": 5.5,
    "europe/berlin": 1, "europe/paris": 1, "europe/moscow": 3,
    "america/new_york": -5, "america/chicago": -6,
    "america/denver": -7, "america/los_angeles": -8,
}

# --------------------------------------------------------------------------
# 工具实现
# --------------------------------------------------------------------------
def _tz_offset(name):
    if name is None:
        return TZ_OFFSETS["asia/shanghai"]
    key = str(name).strip().lower()
    if key in TZ_OFFSETS:
        return TZ_OFFSETS[key]
    # 允许直接传 "+8" / "8" / "UTC+8"
    for prefix in ("utc", "gmt"):
        if key.startswith(prefix):
            key = key[len(prefix):]
    try:
        return float(key)
    except ValueError:
        return None


def t_get_time(args):
    tz = args.get("timezone") or args.get("tz") or "Asia/Shanghai"
    off = _tz_offset(tz)
    if off is None:
        return u"不支持的时区：%s\n可用时区：%s" % (tz, ", ".join(sorted(TZ_OFFSETS.keys())))
    now = datetime.datetime.utcnow() + datetime.timedelta(hours=off)
    ah = abs(off)
    hh = int(ah)
    mm = int(round((ah - hh) * 60))
    sign = "+" if off >= 0 else "-"
    return u"%s 当前时间：%s（UTC%s%02d:%02d）" % (
        tz, now.strftime("%Y-%m-%d %H:%M:%S"), sign, hh, mm)


def t_echo(args):
    text = args.get("text")
    if text is None:
        text = args.get("message", "")
    return u"echo: %s" % text


def t_add(args):
    try:
        x = float(args.get("a"))
        y = float(args.get("b"))
    except (TypeError, ValueError):
        return u"参数 a、b 必须是数字，例如 {\"a\": 1, \"b\": 2}"
    s = x + y
    if s == int(s):
        return u"%s + %s = %d" % (_num(x), _num(y), int(s))
    return u"%s + %s = %s" % (_num(x), _num(y), s)


def _num(v):
    return ("%d" % v) if v == int(v) else ("%s" % v)


TOOL_IMPL = {
    "get_time": t_get_time,
    "echo": t_echo,
    "add": t_add,
}

TOOL_DEFS = [
    {
        "name": "get_time",
        "description": u"获取指定时区的当前日期和时间。不传时区默认 Asia/Shanghai。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "timezone": {
                    "type": "string",
                    "description": u"时区名，如 Asia/Shanghai、UTC、Asia/Tokyo",
                }
            },
            "required": [],
        },
    },
    {
        "name": "echo",
        "description": u"把传入的文本原样回显，用来验证 MCP 链路是否打通。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": u"要回显的文本"}
            },
            "required": ["text"],
        },
    },
    {
        "name": "add",
        "description": u"计算两个数字相加的结果。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "a": {"type": "number", "description": u"第一个加数"},
                "b": {"type": "number", "description": u"第二个加数"},
            },
            "required": ["a", "b"],
        },
    },
]


# --------------------------------------------------------------------------
# JSON-RPC 分发
# --------------------------------------------------------------------------
def _ok(msg_id, result):
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def _err(msg_id, code, message):
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}


def dispatch(msg):
    """返回 (response_dict_or_None, is_notification)"""
    if not isinstance(msg, dict):
        return _err(None, -32600, "Invalid Request"), False

    method = msg.get("method")
    msg_id = msg.get("id")
    params = msg.get("params") or {}
    is_notification = "id" not in msg

    if method == "initialize":
        proto = params.get("protocolVersion") or FALLBACK_PROTOCOL
        result = {
            "protocolVersion": proto,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": u"mini-mcp：演示用最小 MCP Server，提供 get_time / echo / add。",
        }
        return _ok(msg_id, result), is_notification

    if method in ("notifications/initialized", "initialized"):
        return None, True

    if method == "ping":
        return _ok(msg_id, {}), is_notification

    if method == "tools/list":
        return _ok(msg_id, {"tools": TOOL_DEFS}), is_notification

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if not isinstance(args, dict):
            args = {}
        fn = TOOL_IMPL.get(name)
        if fn is None:
            return _err(msg_id, -32602, "Unknown tool: %s" % name), is_notification
        try:
            text = fn(args)
        except Exception as exc:  # 工具内部异常也要按 MCP 规范回成 content
            return _ok(msg_id, {
                "content": [{"type": "text", "text": u"工具执行异常：%s" % exc}],
                "isError": True,
            }), is_notification
        return _ok(msg_id, {
            "content": [{"type": "text", "text": text}],
            "isError": False,
        }), is_notification

    if method == "resources/list":
        return _ok(msg_id, {"resources": []}), is_notification

    if method == "prompts/list":
        return _ok(msg_id, {"prompts": []}), is_notification

    if is_notification:
        return None, True

    return _err(msg_id, -32601, "Method not found: %s" % method), is_notification


# --------------------------------------------------------------------------
# 旧式 SSE 会话表（GET /sse 建立，POST /message 投递）
# --------------------------------------------------------------------------
SESSIONS = {}
SESSIONS_LOCK = threading.Lock()


class SseSession(object):
    def __init__(self, sid):
        self.id = sid
        self.queue = []
        self.cond = threading.Condition()

    def push(self, obj):
        with self.cond:
            self.queue.append(json.dumps(obj, ensure_ascii=False))
            self.cond.notify_all()

    def drain(self, timeout):
        with self.cond:
            if not self.queue:
                self.cond.wait(timeout)
            out = self.queue[:]
            del self.queue[:]
            return out


# --------------------------------------------------------------------------
# HTTP 处理
# --------------------------------------------------------------------------
class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    server_version = "%s/%s" % (SERVER_NAME, SERVER_VERSION)
    protocol_version = "HTTP/1.1"
    session_id = uuid.uuid4().hex

    # ---- 基础输出 ----
    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, text_type):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra:
                self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, code, obj, extra=None):
        self._send(code, json.dumps(obj, ensure_ascii=False), extra=extra)

    def log_message(self, fmt, *args):
        sys.stdout.write("[%s] %s - %s\n" % (
            time.strftime("%Y-%m-%d %H:%M:%S"), self.address_string(), fmt % args))
        sys.stdout.flush()

    # ---- 路由 ----
    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/health", "/healthz"):
            self._json(200, {
                "status": "ok",
                "server": SERVER_NAME,
                "version": SERVER_VERSION,
                "transport": "streamable-http + sse",
                "endpoints": {"streamable_http": "/mcp", "sse": "/sse"},
                "tools": sorted(TOOL_IMPL.keys()),
                "python": sys.version.split()[0],
                "sse_sessions": len(SESSIONS),
            })
        elif path in ("/sse", "/sse/"):
            self._serve_sse()
        elif path in ("/mcp", "/mcp/"):
            # 规范允许服务端不支持服务端推送时返回 405
            self._json(405, {"error": "SSE stream not supported on this path, use POST /mcp"})
        else:
            self._json(404, {"error": "not found", "path": path})

    def _serve_sse(self):
        sid = uuid.uuid4().hex
        sess = SseSession(sid)
        with SESSIONS_LOCK:
            SESSIONS[sid] = sess
        # 长连接没有 Content-Length，用 HTTP/1.0 语义（读到 EOF 结束）
        self.protocol_version = "HTTP/1.0"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(("event: endpoint\ndata: /message?sessionId=%s\n\n" % sid).encode("utf-8"))
            self.wfile.flush()
            last_ping = time.time()
            while True:
                msgs = sess.drain(1.0)
                for m in msgs:
                    chunk = u"event: message\ndata: %s\n\n" % m
                    self.wfile.write(chunk.encode("utf-8"))
                if msgs:
                    self.wfile.flush()
                elif time.time() - last_ping > 15:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    last_ping = time.time()
        except Exception:
            pass
        finally:
            with SESSIONS_LOCK:
                SESSIONS.pop(sid, None)

    def do_DELETE(self):
        self._json(200, {"ok": True})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path not in ("/mcp", "/message", "/messages"):
            self._json(404, {"error": "not found", "path": parsed.path})
            return

        # SSE 方式：从 query 里取 sessionId
        sid = None
        if path != "/mcp":
            qs = parse_qs(parsed.query)
            sid = (qs.get("sessionId") or qs.get("session_id") or [None])[0]

        # 读请求体
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except (TypeError, ValueError):
            length = 0
        raw = self.rfile.read(length) if length > 0 else b""
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "replace")

        if not raw.strip():
            self._json(400, _err(None, -32700, "Parse error: empty body"))
            return

        try:
            payload = json.loads(raw)
        except Exception as exc:
            self._json(400, _err(None, -32700, "Parse error: %s" % exc))
            return

        # 支持批量请求
        if isinstance(payload, list):
            out = []
            for item in payload:
                resp, _ = dispatch(item)
                if resp is not None:
                    out.append(resp)
            if sid:
                if self._push_to_session(sid, out):
                    self._send(202, b"")
                return
            if not out:
                self._send(202, b"")
            else:
                self._json(200, out, extra=self._session_header())
            return

        resp, is_notification = dispatch(payload)

        # SSE 方式：结果从 /sse 流里推回，本请求只回 202
        if sid:
            if self._push_to_session(sid, resp):
                self._send(202, b"")
            return

        if resp is None:
            # 通知类消息：202 无 body
            self._send(202, b"", extra=self._session_header())
            return
        self._json(200, resp, extra=self._session_header())

    def _push_to_session(self, sid, obj):
        with SESSIONS_LOCK:
            sess = SESSIONS.get(sid)
        if sess is None:
            self._json(404, _err(None, -32001, "Unknown sessionId: %s" % sid))
            return False
        if obj is None:
            return True
        if isinstance(obj, list):
            for item in obj:
                sess.push(item)
        else:
            sess.push(obj)
        return True

    def _session_header(self):
        return [("Mcp-Session-Id", self.session_id)]


def main():
    port = 8765
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass
    srv = ThreadedHTTPServer(("0.0.0.0", port), Handler)
    sys.stdout.write(
        "%s %s ready\n  python : %s\n  listen : 0.0.0.0:%d\n"
        "  health : http://127.0.0.1:%d/\n  mcp    : http://127.0.0.1:%d/mcp   (Streamable HTTP)\n"
        "  sse    : http://127.0.0.1:%d/sse   (旧式 SSE)\n"
        "  tools  : %s\n"
        % (SERVER_NAME, SERVER_VERSION, sys.version.split()[0], port, port, port, port,
           ", ".join(sorted(TOOL_IMPL.keys()))))
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        sys.stdout.write("\nbye\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
