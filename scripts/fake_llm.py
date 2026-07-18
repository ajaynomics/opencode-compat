#!/usr/bin/env python3
"""Deterministic OpenAI-compatible streaming server for image contracts."""

from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[dict[str, object]] = []

    def record(self, path: str, body: object) -> None:
        with self.lock:
            self.requests.append({"path": path, "body": body, "at": time.time()})

    def snapshot(self) -> dict[str, object]:
        with self.lock:
            return {"request_count": len(self.requests), "requests": list(self.requests)}


STATE = State()


def chat_stream(text: str) -> bytes:
    chunks = [
        {
            "id": "chatcmpl-opencode-compat",
            "object": "chat.completion.chunk",
            "choices": [{"delta": {"role": "assistant"}}],
        },
        {
            "id": "chatcmpl-opencode-compat",
            "object": "chat.completion.chunk",
            "choices": [{"delta": {"content": text}}],
        },
        {
            "id": "chatcmpl-opencode-compat",
            "object": "chat.completion.chunk",
            "choices": [{"delta": {}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7},
        },
    ]
    payload = "".join(f"data: {json.dumps(chunk, separators=(',', ':'))}\n\n" for chunk in chunks)
    payload += "data: [DONE]\n\n"
    return payload.encode()


class Handler(BaseHTTPRequestHandler):
    server_version = "OpenCodeCompatLLM/1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_bytes(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self.send_bytes(200, b'{"ok":true}', "application/json")
            return
        if self.path == "/stats":
            self.send_bytes(200, json.dumps(STATE.snapshot()).encode(), "application/json")
            return
        if self.path == "/v1/models":
            body = {"object": "list", "data": [{"id": "compat-model", "object": "model"}]}
            self.send_bytes(200, json.dumps(body).encode(), "application/json")
            return
        self.send_bytes(404, b'{"error":"not found"}', "application/json")

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            body = {"invalid_json": raw.decode(errors="replace")}
        STATE.record(self.path, body)

        if self.path == "/v1/chat/completions":
            self.send_bytes(200, chat_stream("compat-ok"), "text/event-stream")
            return

        self.send_bytes(404, b'{"error":"unsupported endpoint"}', "application/json")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    Path(args.port_file).write_text(str(server.server_port), encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
