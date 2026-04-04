#!/usr/bin/env python3
import json
import os
import plistlib
import socket
import subprocess
import sys
from pathlib import Path

LOCAL_HEALTH = "http://127.0.0.1:9700/health"
REMOTE_HOST = "mcp.kup.solutions"
REMOTE_HEALTH = f"https://{REMOTE_HOST}/health"
REMOTE_MCP = f"https://{REMOTE_HOST}/mcp"
PLIST_PATH = Path.home() / "Library/Preferences/kup.solutions.notion-bridge.plist"
TOKEN_KEY = "com.notionbridge.mcpBearerToken"


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=45)


def curl(url, extra_args=None, headers=None, data=None, resolve_ip=None):
    cmd = ["curl", "-sS", "-i"]
    if resolve_ip:
        host = url.split('/')[2]
        cmd.extend(["--resolve", f"{host}:443:{resolve_ip}"])
    if headers:
        for k, v in headers.items():
            cmd.extend(["-H", f"{k}: {v}"])
    if data is not None:
        cmd.extend(["-d", data])
    if extra_args:
        cmd.extend(extra_args)
    cmd.append(url)
    return run(cmd)


def parse_status(stdout):
    for line in stdout.splitlines():
        if line.startswith("HTTP/"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                return int(parts[1])
    return None


def load_token():
    if os.environ.get("MCP_REMOTE_TOKEN"):
        return os.environ["MCP_REMOTE_TOKEN"].strip()
    if PLIST_PATH.exists():
        try:
            data = plistlib.loads(PLIST_PATH.read_bytes())
            token = (data.get(TOKEN_KEY) or "").strip()
            if token:
                return token
        except Exception:
            pass
    return ""


def resolve_public_ips(host):
    dig = run(["dig", "+short", "@1.1.1.1", host])
    ips = [line.strip() for line in dig.stdout.splitlines() if line.strip()]
    if ips:
        return ips
    try:
        return socket.gethostbyname_ex(host)[2]
    except Exception:
        return []


def assert_true(condition, message, detail=None):
    if not condition:
        if detail:
            raise AssertionError(f"{message}: {detail}")
        raise AssertionError(message)


def main():
    token = load_token()
    ips = resolve_public_ips(REMOTE_HOST)
    assert_true(bool(ips), "Remote MCP host did not resolve")
    ip = ips[0]

    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "qa-remote-mcp", "version": "1.0"},
        },
    })

    results = []

    local = curl(LOCAL_HEALTH)
    local_status = parse_status(local.stdout)
    assert_true(local_status == 200, "Local health probe failed", local.stdout[:400])
    results.append({"check": "local_health", "status": local_status, "pass": True})

    remote_health = curl(REMOTE_HEALTH, resolve_ip=ip)
    remote_health_status = parse_status(remote_health.stdout)
    assert_true(remote_health_status == 200, "Remote health probe failed", remote_health.stdout[:400])
    results.append({"check": "remote_health", "status": remote_health_status, "pass": True, "ip": ip})

    unauth = curl(
        REMOTE_MCP,
        resolve_ip=ip,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
        data=payload,
    )
    unauth_status = parse_status(unauth.stdout)
    assert_true(unauth_status == 401, "Unauthenticated initialize did not fail with 401", unauth.stdout[:700])
    assert_true("missing Bearer token" in unauth.stdout, "Unauthenticated initialize did not explain missing bearer", unauth.stdout[:700])
    results.append({"check": "remote_initialize_unauthorized", "status": unauth_status, "pass": True})

    assert_true(bool(token), "No MCP remote token found in preferences or environment")
    auth = curl(
        REMOTE_MCP,
        resolve_ip=ip,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
        data=payload,
    )
    auth_status = parse_status(auth.stdout)
    assert_true(auth_status == 200, "Authenticated initialize did not succeed", auth.stdout[:900])
    lower_auth = auth.stdout.lower()
    assert_true("content-type: text/event-stream" in lower_auth, "Authenticated initialize did not open SSE stream", auth.stdout[:900])
    assert_true("mcp-session-id:" in lower_auth, "Authenticated initialize missing mcp-session-id header", auth.stdout[:900])
    assert_true('"serverinfo"' in lower_auth or '"serverInfo"' in auth.stdout, "Authenticated initialize missing server info payload", auth.stdout[:900])
    results.append({"check": "remote_initialize_authorized", "status": auth_status, "pass": True})


    print(json.dumps({
        "remote_host": REMOTE_HOST,
        "resolved_ip": ip,
        "checks": results,
    }, indent=2))


if __name__ == "__main__":
    try:
        main()
    except AssertionError as e:
        print(json.dumps({"pass": False, "error": str(e)}, indent=2))
        sys.exit(1)
