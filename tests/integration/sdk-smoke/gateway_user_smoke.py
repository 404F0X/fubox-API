#!/usr/bin/env python3
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request


GATEWAY_BASE_URL = os.getenv("GATEWAY_BASE_URL", "http://127.0.0.1:8080").rstrip("/")
API_KEY = os.getenv("GATEWAY_API_KEY") or os.getenv("OPENAI_API_KEY") or os.getenv("GATEWAY_AUTH_TOKEN") or ""
MODEL = os.getenv("SMOKE_MODEL", "mock-gpt-4o-mini")
TIMEOUT_SECONDS = int(os.getenv("SDK_SMOKE_TIMEOUT_SECONDS", "15"))


SUMMARY = {
    "schema": "fubox_gateway_user_mvp_summary.v1",
    "artifact_kind": "local_mvp_sdk_smoke_summary",
    "local_only": True,
    "production_evidence": False,
    "secret_safe": True,
    "model": MODEL,
    "gateway_models": {
        "endpoint": "/v1/models",
        "status": "not_run",
        "model_count": 0,
        "contains_expected_model": False,
    },
    "gateway_requests": {
        "non_stream": {
            "endpoint": "/v1/chat/completions",
            "stream": False,
            "status": "not_run",
            "request_id": None,
            "trace_id": None,
        },
        "stream": {
            "endpoint": "/v1/chat/completions",
            "stream": True,
            "status": "not_run",
            "request_id": None,
            "trace_id": None,
        },
    },
    "readback": {
        "user_request_logs": {
            "status": "not_run_sdk_gateway_only",
            "detail": "Run scripts/dev_login_check.ps1 for control-plane user request log readback.",
        },
        "admin_request_detail": {
            "status": "not_run_sdk_gateway_only",
            "detail": "Run scripts/dev_login_check.ps1 for admin request detail readback.",
        },
    },
}


def redact(value):
    text = str(value)
    text = re.sub(r"Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer [REDACTED]", text, flags=re.I)
    text = re.sub(r"(api[_-]?key|authorization|token|secret)([\"'\s:=]+)[^\"'\s,}]+", r"\1\2[REDACTED]", text, flags=re.I)
    text = re.sub(r"sk-[A-Za-z0-9._-]+", "sk-[REDACTED]", text)
    return text


def require_api_key():
    if not API_KEY.strip():
        raise RuntimeError("missing API key; set GATEWAY_API_KEY or OPENAI_API_KEY")


def make_trace_id(label):
    suffix = f"{random.getrandbits(32):08x}"
    return f"user-smoke-{label}-{int(time.time() * 1000)}-{suffix}"


def request_json(path, method="GET", body=None, trace_id=None):
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    }
    if trace_id:
        headers["x-ai-trace-id"] = trace_id
    payload = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(f"{GATEWAY_BASE_URL}{path}", data=payload, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            raw = response.read().decode("utf-8")
            return {
                "payload": json.loads(raw) if raw.strip() else None,
                "request_id": response.headers.get("x-request-id"),
                "trace_id": trace_id,
            }
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {error.code}: {raw}") from error


def request_stream(path, body, trace_id):
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
        "x-ai-trace-id": trace_id,
    }
    request = urllib.request.Request(
        f"{GATEWAY_BASE_URL}{path}",
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            request_id = response.headers.get("x-request-id")
            chunks = 0
            done = False
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if not data:
                    continue
                chunks += 1
                if data == "[DONE]":
                    done = True
            return {
                "request_id": request_id,
                "trace_id": trace_id,
                "chunks": chunks,
                "done": done,
            }
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {error.code}: {raw}") from error


def print_json(value):
    print(json.dumps(value, separators=(",", ":")))


def main():
    require_api_key()

    models = request_json("/v1/models")
    model_data = models["payload"].get("data", []) if isinstance(models["payload"], dict) else []
    model_ids = [entry.get("id") for entry in model_data if isinstance(entry, dict) and entry.get("id")]
    SUMMARY["gateway_models"]["status"] = "pass"
    SUMMARY["gateway_models"]["model_count"] = len(model_ids)
    SUMMARY["gateway_models"]["contains_expected_model"] = MODEL in model_ids
    print_json({
        "step": "models",
        "model_count": len(model_ids),
        "models": model_ids,
    })

    non_stream_trace_id = make_trace_id("non-stream")
    non_stream = request_json(
        "/v1/chat/completions",
        method="POST",
        trace_id=non_stream_trace_id,
        body={
            "model": MODEL,
            "messages": [{"role": "user", "content": "Return the word ok."}],
            "stream": False,
        },
    )
    non_stream_payload = non_stream["payload"] if isinstance(non_stream["payload"], dict) else {}
    choices = non_stream_payload.get("choices") if isinstance(non_stream_payload.get("choices"), list) else []
    SUMMARY["gateway_requests"]["non_stream"]["status"] = "pass"
    SUMMARY["gateway_requests"]["non_stream"]["request_id"] = non_stream["request_id"]
    SUMMARY["gateway_requests"]["non_stream"]["trace_id"] = non_stream["trace_id"]
    print_json({
        "step": "chat_non_stream",
        "request_id": non_stream["request_id"],
        "trace_id": non_stream["trace_id"],
        "response_id": non_stream_payload.get("id"),
        "finish_reason": choices[0].get("finish_reason") if choices and isinstance(choices[0], dict) else None,
    })

    stream_trace_id = make_trace_id("stream")
    stream = request_stream(
        "/v1/chat/completions",
        {
            "model": MODEL,
            "messages": [{"role": "user", "content": "Stream the word ok."}],
            "stream": True,
        },
        stream_trace_id,
    )
    SUMMARY["gateway_requests"]["stream"]["status"] = "pass"
    SUMMARY["gateway_requests"]["stream"]["request_id"] = stream["request_id"]
    SUMMARY["gateway_requests"]["stream"]["trace_id"] = stream["trace_id"]
    print_json({
        "step": "chat_stream",
        "request_id": stream["request_id"],
        "trace_id": stream["trace_id"],
        "sse_chunks": stream["chunks"],
        "done": stream["done"],
    })
    print_json({
        "step": "gateway_user_mvp_summary",
        "summary": SUMMARY,
    })


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("[FAIL] Gateway user smoke failed", file=sys.stderr)
        print(redact(exc), file=sys.stderr)
        sys.exit(1)
