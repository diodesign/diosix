"""Local OpenAI-compatible mock LLM gateway backend for QEMU E2E tests."""

import base64
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.dont_write_bytecode = True

KV_SERVE_SH = (
    "#!/bin/sh\n"
    "D=/var/lib/diosix-kv; mkdir -p $D\n"
    "IFS= read -r l || exit 0\n"
    "r=$(printf '\\r'); set -- ${l%$r}; p=$2\n"
    "while IFS= read -r h; do [ -z \"${h%$r}\" ] && break; done\n"
    "q=${p#*\\?}\n"
    "k=$(printf '%s\\n' \"$q\"|"
    "sed -n 's/.*key=\\([^&]*\\).*/\\1/p'|tr -cd A-Za-z0-9_.-)\n"
    "v=$(printf '%s\\n' \"$q\"|"
    "sed -n 's/.*val=\\([^&]*\\).*/\\1/p'|tr -cd A-Za-z0-9_.-)\n"
    "[ -z \"$k\" ] && k=default\n"
    "if [ -n \"$v\" ]; then printf '%s\\n' \"$v\" > \"$D/$k\"; "
    "b=\"OK:$v\"\n"
    "else b=$(cat \"$D/$k\" 2>/dev/null || echo NOT_FOUND); fi\n"
    "printf 'HTTP/1.0 200 OK\\r\\nContent-Length: %d\\r\\n\\r\\n%s\\n' "
    "\"$((${#b}+1))\" \"$b\"\n"
)

KV_SERVE_B64 = base64.b64encode(KV_SERVE_SH.encode()).decode()

KV_SETUP_CMD = (
    "PATH=$PATH:/usr/local/sbin:/usr/local/bin; "
    "iptables -I INPUT 1 -p tcp --dport 8088 -j ACCEPT "
    "2>/dev/null || true; "
    "D=/var/lib/diosix-kv; mkdir -p $D && printf '%s' '"
    + KV_SERVE_B64
    + "' | base64 -d > $D/serve.sh && chmod 755 $D/serve.sh && "
    "F=$D/nc.pid; ([ -s $F ] && kill $(cat $F) 2>/dev/null || true); "
    "busybox nc -lk -p 8088 -e /bin/sh $D/serve.sh "
    "</dev/null >/dev/null 2>&1 & echo $! > $F; sleep 1"
)


def _deploy_kv_plan():
    return {
        "summary": "Deployed replicated KV cluster and edge monitor",
        "actions": [
            {
                "action": "spawn_vm",
                "name": "kv-1",
                "ram": "128M",
                "leaf": True,
            },
            {
                "action": "spawn_vm",
                "name": "kv-2",
                "ram": "128M",
                "leaf": True,
            },
            {
                "action": "spawn_vm",
                "name": "edge-mon",
                "ram": "128M",
                "leaf": True,
                "tokens": "8000",
                "budget_usd": "0.05",
                "max_thinking": "low",
            },
            {
                "action": "ssh_child",
                "target": "kv-1",
                "cmd": KV_SETUP_CMD,
            },
            {
                "action": "ssh_child",
                "target": "kv-2",
                "cmd": KV_SETUP_CMD,
            },
        ],
    }


def _repair_kv_plan(prompt_text):
    tail = prompt_text.split("ALERT_REPAIR:", 1)[-1]
    failed = "kv-2" if "kv-2" in tail else "kv-1"
    peer = "kv-1" if failed == "kv-2" else "kv-2"
    sync_cmd = (
        f"F=$(awk '/^name = \"{failed}\"$/{{f=1}} "
        "f&&/^ip = \"/{{gsub(/\"/,\"\",$3);print $3;exit}}' "
        "/run/diosix/guests.toml); "
        f"P=$(awk '/^name = \"{peer}\"$/{{f=1}} "
        "f&&/^ip = \"/{{gsub(/\"/,\"\",$3);print $3;exit}}' "
        "/run/diosix/guests.toml); "
        "V=$(wget -qO- \"http://$P:8088/kv?key=mission_state\" | "
        "tr -cd A-Za-z0-9_.-); "
        "[ -n \"$V\" ] && [ \"$V\" != NOT_FOUND ] && "
        "wget -qO- \"http://$F:8088/kv?key=mission_state&val=$V\" || true"
    )
    return {
        "summary": f"Respawned {failed} and synced state from {peer}",
        "actions": [
            {"action": "stop_vm", "target": failed},
            {
                "action": "spawn_vm",
                "name": failed,
                "ram": "128M",
                "leaf": True,
            },
            {"action": "ssh_child", "target": failed, "cmd": KV_SETUP_CMD},
            {"action": "run_cmd", "cmd": sync_cmd},
        ],
    }


def build_mock_reply(prompt_text):
    if "ALERT_REPAIR:" in prompt_text:
        return json.dumps(_repair_kv_plan(prompt_text))
    if "DEPLOY_KV_CLUSTER" in prompt_text:
        return json.dumps(_deploy_kv_plan())
    if (
        "min=0" in prompt_text
        or "encrypt_volumes=true" in prompt_text
        or "wipe_volumes=true" in prompt_text
    ):
        return json.dumps(
            {
                "decision": "reject",
                "summary": "Mock LLM vetoed destructive charter change",
            }
        )
    return json.dumps(
        {
            "decision": "approve",
            "summary": "Mock LLM approved constitutional invariants",
        }
    )


class MockOpenAiServer:
    """Thread-safe OpenAI /v1/chat/completions mock bound to 127.0.0.1."""

    def __init__(self, expected_bearer="sk-root-only-test"):
        self.expected_bearer = expected_bearer
        self.lock = threading.Lock()
        self.requests = []
        self.auth_failures = 0
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                return

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(min(length, 262144))
                auth = self.headers.get("Authorization", "")
                if outer.expected_bearer:
                    want = f"Bearer {outer.expected_bearer}"
                    if auth != want:
                        with outer.lock:
                            outer.auth_failures += 1
                        self.send_response(401)
                        self.end_headers()
                        self.wfile.write(b'{"error":"unauthorized"}\n')
                        return
                try:
                    req = json.loads(raw.decode("utf-8", errors="replace"))
                except Exception:
                    self.send_response(400)
                    self.end_headers()
                    return

                msgs = req.get("messages", [])
                joined = "\n".join(str(m.get("content", "")) for m in msgs)
                model = str(req.get("model", "mock-llm"))
                ans = build_mock_reply(joined)
                in_tok = max(16, len(joined) // 4)
                out_tok = max(12, len(ans) // 4)
                with outer.lock:
                    outer.requests.append((model, joined[:80]))

                payload = json.dumps(
                    {
                        "id": "chatcmpl-diosix-mock",
                        "object": "chat.completion",
                        "model": model,
                        "choices": [
                            {
                                "index": 0,
                                "message": {
                                    "role": "assistant",
                                    "content": ans,
                                },
                                "finish_reason": "stop",
                            }
                        ],
                        "usage": {
                            "prompt_tokens": in_tok,
                            "completion_tokens": out_tok,
                            "total_tokens": in_tok + out_tok,
                        },
                    }
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(
            target=self.srv.serve_forever, daemon=True
        )
        self.thread.start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()
