#!/usr/bin/env python3
"""muse-spark-shim — expose the Muse VM's Space inference socket as an
OpenAI-compatible HTTP endpoint.

The Muse runtime owns /run/hatch/sandbox/space-inference.sock, which speaks
length-prefixed JSON frames ({kind:"complete", slug, prompt, system?}).
This shim translates /v1/chat/completions (and /v1/models) into those frames
so 9Router can use Muse Spark as a normal OpenAI provider.

No credentials involved: the socket is local to the Muse VM and gated by the
Muse runtime itself.
"""
import json
import os
import socket
import struct
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOCK = os.environ.get("MUSE_INFERENCE_SOCK",
                      "/run/hatch/sandbox/space-inference.sock")
SLUG = os.environ.get("MUSE_SPACE_SLUG", "__probe__")
HOST = os.environ.get("MUSE_SHIM_HOST", "127.0.0.1")
PORT = int(os.environ.get("MUSE_SHIM_PORT", "8766"))
MODEL = os.environ.get("MUSE_SHIM_MODEL", "muse-spark-1.3")
DEFAULT_TIMEOUT = int(os.environ.get("MUSE_SHIM_TIMEOUT", "180"))
MAX_FRAME = 32 * 1024 * 1024


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise RuntimeError("inference socket closed early")
        buf += chunk
    return buf


def complete(prompt, system=None, timeout=DEFAULT_TIMEOUT):
    """One Muse Spark turn over the Space inference socket."""
    req = {
        "kind": "complete",
        "request_id": "shim-" + uuid.uuid4().hex,
        "slug": SLUG,
        "prompt": prompt,
        "timeout_secs": max(1, int(timeout)),
    }
    if system:
        req["system"] = system
    payload = json.dumps(req).encode("utf-8")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(int(timeout) + 30)
    try:
        s.connect(SOCK)
        s.sendall(struct.pack(">I", len(payload)) + payload)
        n = struct.unpack(">I", _recv_exact(s, 4))[0]
        if n > MAX_FRAME:
            raise RuntimeError("response frame too large")
        body = _recv_exact(s, n)
    finally:
        s.close()
    resp = json.loads(body.decode("utf-8"))
    if not resp.get("ok"):
        raise RuntimeError(resp.get("error") or "inference failed")
    return resp.get("result") or {}


def flatten(messages):
    """OpenAI messages -> (system, prompt). Muse takes one prompt string."""
    system_parts, turns = [], []
    for m in messages or []:
        if not isinstance(m, dict):
            continue
        role = m.get("role")
        content = m.get("content")
        if isinstance(content, list):
            content = "".join(
                p.get("text", "") for p in content
                if isinstance(p, dict) and p.get("type") == "text"
            )
        content = content or ""
        if role == "system":
            system_parts.append(content)
        elif role == "assistant":
            turns.append("Assistant: " + content)
        elif role == "tool":
            turns.append("Tool: " + content)
        else:
            turns.append("User: " + content)
    return ("\n\n".join(system_parts) or None,
            "\n\n".join(turns) or "Hello")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[shim] " + (fmt % args) + "\n")

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path in ("/v1/models", "/models"):
            self._json(200, {"object": "list", "data": [
                {"id": MODEL, "object": "model", "owned_by": "muse"}]})
        elif path in ("/health", "/healthz", ""):
            self._json(200, {"ok": True, "model": MODEL, "socket": SOCK})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")
        if path not in ("/v1/chat/completions", "/chat/completions"):
            self._json(404, {"error": {"message": "not found"}})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception as exc:
            self._json(400, {"error": {"message": "bad json: %s" % exc}})
            return

        system, prompt = flatten(body.get("messages"))
        try:
            res = complete(prompt, system, body.get("timeout") or DEFAULT_TIMEOUT)
        except Exception as exc:
            self._json(502, {"error": {"message": str(exc)}})
            return

        text = res.get("content")
        if not isinstance(text, str):
            text = json.dumps(text, ensure_ascii=False)
        usage = res.get("usage") or {}
        created = int(time.time())
        cid = "chatcmpl-" + uuid.uuid4().hex
        model = res.get("model") or MODEL

        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            delta = {"id": cid, "object": "chat.completion.chunk",
                     "created": created, "model": model,
                     "choices": [{"index": 0, "finish_reason": None,
                                  "delta": {"role": "assistant", "content": text}}]}
            self.wfile.write(("data: " + json.dumps(delta) + "\n\n").encode())
            done = {"id": cid, "object": "chat.completion.chunk",
                    "created": created, "model": model,
                    "choices": [{"index": 0, "finish_reason": "stop", "delta": {}}]}
            self.wfile.write(("data: " + json.dumps(done) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return

        self._json(200, {
            "id": cid,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": text}}],
            "usage": {
                "prompt_tokens": usage.get("input_tokens", 0),
                "completion_tokens": usage.get("output_tokens", 0),
                "total_tokens": usage.get("total_tokens", 0),
            },
        })


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    sys.stderr.write("[shim] http://%s:%d -> %s (model %s)\n"
                     % (HOST, PORT, SOCK, MODEL))
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
