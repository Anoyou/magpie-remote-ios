#!/usr/bin/env python3
"""Tiny OpenAI-compatible mock upstream for magpie contract tests.

GET  /v1/models                -> two models
POST /v1/chat/completions      -> stream (SSE, with usage chunk) or plain JSON
POST /v1/responses             -> minimal non-stream answer (in case magpie translates)
Usage: python3 mock_openai.py [port]   (default 18080, binds 0.0.0.0)
Every request is appended to $MOCK_LOG (default /tmp/mock_openai.log).
"""
import json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
LOG = os.environ.get("MOCK_LOG", "/tmp/mock_openai.log")
MODELS = ["mock-gpt-1", "mock-gpt-mini"]
TEXT = "Hello from the mock upstream."


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % a))

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        with open(LOG, "a") as f:
            f.write("BODY %s %s\n" % (self.path, raw[:2000].decode("utf-8", "replace")))
        try:
            return json.loads(raw or b"{}")
        except Exception:
            return {}

    def do_GET(self):
        p = self.path.split("?")[0].rstrip("/")
        if p in ("/v1/models", "/models"):
            now = int(time.time())
            return self._json(200, {"object": "list", "data": [
                {"id": m, "object": "model", "created": now, "owned_by": "mock"} for m in MODELS]})
        self._json(404, {"error": {"message": "not found: " + self.path}})

    def do_POST(self):
        p = self.path.split("?")[0].rstrip("/")
        body = self._body()
        model = body.get("model") or MODELS[0]
        cid = "chatcmpl-" + uuid.uuid4().hex[:12]
        now = int(time.time())
        usage = {"prompt_tokens": 12, "completion_tokens": 7, "total_tokens": 19}
        if p in ("/v1/chat/completions", "/chat/completions"):
            if body.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()

                def ev(obj):
                    self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
                    self.wfile.flush()

                base = {"id": cid, "object": "chat.completion.chunk", "created": now, "model": model}
                ev({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}]})
                for w in TEXT.split(" "):
                    ev({**base, "choices": [{"index": 0, "delta": {"content": w + " "}, "finish_reason": None}]})
                    time.sleep(0.02)
                ev({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
                ev({**base, "choices": [], "usage": usage})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True
                return
            return self._json(200, {"id": cid, "object": "chat.completion", "created": now, "model": model,
                                    "choices": [{"index": 0, "message": {"role": "assistant", "content": TEXT},
                                                 "finish_reason": "stop"}], "usage": usage})
        if p in ("/v1/responses", "/responses"):
            return self._json(200, {"id": "resp_" + cid, "object": "response", "created_at": now, "model": model,
                                    "status": "completed", "output": [{"type": "message", "role": "assistant",
                                    "content": [{"type": "output_text", "text": TEXT}]}],
                                    "usage": {"input_tokens": 12, "output_tokens": 7, "total_tokens": 19}})
        self._json(404, {"error": {"message": "not found: " + self.path}})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
