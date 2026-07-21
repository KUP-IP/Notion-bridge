#!/usr/bin/env bash
# w5b-live-smoke.sh — post-install feature smoke for W5B / continuity.
# Exits non-zero on any FAIL. Does not print secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - <<'PY'
import json, urllib.request, subprocess, sys

def sh(cmd):
    return subprocess.check_output(cmd, shell=True, text=True).strip()

results = []

def ok(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print(("PASS" if cond else "FAIL"), name, detail)

bid = sh("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '/Applications/The Bridge.app/Contents/Info.plist'")
ok("installed_bundle_id", bid == "kup.solutions.the-bridge", bid)
ext = sh("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '/Applications/The Bridge.app/Contents/PlugIns/NotificationContentExtension.appex/Contents/Info.plist'")
ok("extension_bundle_id", ext == "kup.solutions.the-bridge.notification-content", ext)
running = sh("osascript -e 'id of application \"The Bridge\"'")
ok("running_bundle_id", running == "kup.solutions.the-bridge", running)

h = json.load(urllib.request.urlopen("http://127.0.0.1:9700/health", timeout=10))
ok("health_running", h.get("status") == "running", f"tools={h.get('tools')} ver={h.get('version')}")
ok("health_tools_ge_211", (h.get("tools") or 0) >= 211, str(h.get("tools")))
ok("credentials_feature_on", sh("defaults read kup.solutions.the-bridge com.notionbridge.credentialsEnabled") == "1")
ok("acl_heal_suppressed", sh("defaults read kup.solutions.the-bridge 'kup.solutions.the-bridge.keychainACLHealedV1'") == "1")

sha = sh("/usr/libexec/PlistBuddy -c 'Print :BridgeGitSHA' '/Applications/The Bridge.app/Contents/Info.plist' 2>/dev/null || true")
if sha:
    print("INFO installed_gitSHA", sha)

base = "http://127.0.0.1:9700/mcp"

def post(payload, sid=None, timeout=60):
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if sid:
        headers["Mcp-Session-Id"] = sid
    req = urllib.request.Request(base, data=json.dumps(payload).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        sid2 = r.headers.get("Mcp-Session-Id") or sid
        raw = r.read().decode()
        if "data:" in raw:
            raw = "\n".join(
                l[5:].strip()
                for l in raw.splitlines()
                if l.startswith("data:") and l[5:].strip()
            )
        return sid2, raw

sid, _ = post(
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "w5b-live-smoke", "version": "1"},
        },
    }
)
post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)


def call(name, args, rid):
    _, body = post(
        {"jsonrpc": "2.0", "id": rid, "method": "tools/call", "params": {"name": name, "arguments": args}},
        sid,
        timeout=90,
    )
    outer = json.loads(body)
    if "error" in outer:
        return False, outer["error"]
    text = outer["result"]["content"][0]["text"]
    try:
        return True, json.loads(text)
    except Exception:
        return True, {"raw": text[:400]}

ok_bs, bs = call("bridge_status", {}, 2)
ok("bridge_status", ok_bs, str(bs.get("gitSHA", bs))[:80] if isinstance(bs, dict) else str(bs)[:80])

ok_cl, cl = call("credential_list", {}, 3)
ok("credential_list", ok_cl and isinstance(cl, dict) and cl.get("count", 0) >= 1, f"count={cl.get('count') if isinstance(cl, dict) else cl}")
if isinstance(cl, dict):
    hits = [c for c in cl.get("credentials", []) if c.get("service") == "license-ed25519"]
    accounts = sorted({c.get("account") for c in hits})
    ok("license_ed25519_entries", set(accounts) >= {"private", "public"}, str(accounts))

ok_si, _ = call("system_info", {}, 4)
ok("system_info", ok_si)

for svc, acct in [
    ("kup.solutions.the-bridge", "mcp_bearer_token"),
    ("license-ed25519", "private"),
    ("license-ed25519", "public"),
]:
    rc = subprocess.call(
        ["security", "find-generic-password", "-s", svc, "-a", acct],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    ok(f"keychain_exists:{svc}/{acct}", rc == 0, f"rc={rc}")

failed = [n for n, c, _ in results if not c]
print("---")
print(f"SMOKE {len(results) - len(failed)}/{len(results)} passed")
print("OPERATOR_DEMO: Any Keychain password prompt loops since relaunch? Reply PASS or FAIL.")
if failed:
    print("FAILED:", ", ".join(failed))
    sys.exit(1)
PY
