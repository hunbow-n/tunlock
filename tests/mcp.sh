#!/bin/bash
# Talks to `Tunlock --mcp` over stdio like an AI agent would, and checks the
# answers. Needs a built app: tests/mcp.sh [path/to/Tunlock.app/Contents/MacOS/Tunlock]
# Never applies anything: only read-only tools and config validation.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=${1:-build/Tunlock.app/Contents/MacOS/Tunlock}
[[ -x $BIN ]] || { echo "build the app first (./build-app.sh)" >&2; exit 2; }
exec python3 -I - "$BIN" "$PWD/tests/fixtures/good.conf" <<'PY'
import json, subprocess, sys
binary, good_path = sys.argv[1], sys.argv[2]
good = open(good_path).read()
bad = "\n".join("VPS_IP=nope" if l.startswith("VPS_IP=") else l for l in good.splitlines()) + "\n"
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "validate_config", "arguments": {"config": good}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "validate_config", "arguments": {"config": bad}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "propose_config", "arguments": {"config": bad}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "check_proxy", "arguments": {"host": "$(id)", "port": "1"}}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "apply_config", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 8, "method": "no/such"},
    {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "check_exit", "arguments": {"tun_addr": "192.0.2.1"}}},
    {"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "validate_config",
     "arguments": {"config": good + "PROBE_URL=https://1.0.0.1/cdn-cgi/trace\n"}}},
    {"jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": {"name": "detect", "arguments": {}}},
]
out = subprocess.run([binary, "--mcp"], input="".join(json.dumps(m) + "\n" for m in msgs),
                     capture_output=True, text=True, timeout=60).stdout
replies = {r["id"]: r for r in map(json.loads, filter(None, out.splitlines()))}
fails = 0
def check(name, ok):
    global fails
    print(("ok   " if ok else "FAIL ") + "mcp: " + name)
    fails += 0 if ok else 1
def text(i): return replies[i]["result"]["content"][0]["text"]
def is_error(i): return replies[i]["result"]["isError"]

init = replies.get(1, {}).get("result", {})
check("initialize answers with tools and instructions", "tools" in init.get("capabilities", {}) and "never ask for the proxy's login" in init.get("instructions", ""))
check("a notification gets no reply", len(replies) == 11)
names = {t["name"] for t in replies[2]["result"]["tools"]}
check("tools: exactly the safe set", names == {"status", "detect", "check_ssh", "check_proxy", "check_exit", "validate_config", "propose_config"})
check("no tool can apply, switch or uninstall", not names & {"apply_config", "on", "off", "protect", "direct", "uninstall"})
check("validate_config accepts a good config and shows the rules", not is_error(3) and text(3).startswith("VALID") and "block drop quick all" in text(3))
check("validate_config rejects a bad one with the reason", is_error(4) and "VPS_IP" in text(4))
check("propose_config refuses an invalid config", is_error(5))
check("check_proxy refuses shell-looking input", is_error(6) and "IPv4" in text(6))
check("unknown tool is an error", "error" in replies[7])
check("unknown method is an error", replies[8]["error"]["code"] == -32601)
check("check_exit refuses an address that is not on a utun (no direct IP leak)", is_error(9) and "not on any utun" in text(9))
check("an agent cannot change advanced settings like PROBE_URL", is_error(10) and "advanced setting" in text(10))
d = json.loads(text(11))
check("detect sends no exit IPs and no raw config", "exit_via_default_route" not in d and "installed_config" not in d
      and all("exit_ip" not in t for t in d["tun_interfaces"]))
sys.exit(1 if fails else 0)
PY
