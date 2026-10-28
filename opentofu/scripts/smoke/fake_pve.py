#!/usr/bin/env python3
"""A fake Proxmox VE API for smoke tests. No real Proxmox is touched. Every
request is logged as a JSON line: method, path, query, form body, and whether
the Authorization header was the expected one (never the header itself).

    fake_pve.py PORT CERTFILE KEYFILE LOGFILE [REPLAY.json]

Without REPLAY: answers just enough for the bpg/proxmox provider to create,
read, start and destroy CT 980 (the pilot).

With REPLAY (written by capture-replay.sh): a GET is answered only from the
hypervisor's recorded answers; one that isn't recorded gets HTTP 501 and is logged with
"unknown": true. Writes are logged and answered the way PVE would, so a smoke
test can count them.

FAKE_PVE_AUTH_SHA256 (optional): sha256 hex of the expected Authorization
header. Any other header gets HTTP 401, logged as "auth": "bad".
"""
import hashlib
import hmac
import json
import os
import ssl
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, cert, key, logfile = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
replay = json.load(open(sys.argv[5]))["get"] if len(sys.argv) > 5 else None
# The replay stores "@MAC@" instead of a hardware address; substitute the
# per-run value the smoke test generated, so no real MAC lives in the repo.
if replay is not None:
    replay = json.loads(json.dumps(replay).replace("@MAC@", os.environ.get("FAKE_PVE_MAC") or ":".join(["BC", "24", "11", "00", "00", "01"])))
want_auth = os.environ.get("FAKE_PVE_AUTH_SHA256", "")
state = {"exists": False, "running": False}
UPID = "UPID:hypervisor:0000ABCD:00001234:6720A0B0:{t}:980:tofu@pve!pilot:"
CONF = {"hostname": "tofu-pilot", "memory": 256, "swap": 0, "cores": 1,
        "rootfs": "local-lvm:vm-980-disk-0,size=2G", "ostype": "debian",
        "arch": "amd64", "unprivileged": 1, "onboot": 0,
        "description": "OpenTofu pilot - safe to destroy.\n",
        "digest": "0" * 40}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, data, code=200):
        body = json.dumps({"data": data} if code == 200 else {"errors": data, "data": None}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log(self, entry):
        with open(logfile, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def handle_any(self, method):
        u = urllib.parse.urlsplit(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        form = urllib.parse.parse_qs(raw, keep_blank_values=True) if raw and not raw.startswith("{") else (json.loads(raw) if raw else {})
        entry = {"m": method, "p": u.path, "q": u.query, "body": form}
        p = u.path.removeprefix("/api2/json")
        if want_auth:
            got = hashlib.sha256((self.headers.get("Authorization") or "").encode()).hexdigest()
            entry["auth"] = "ok" if hmac.compare_digest(got, want_auth) else "bad"
            if entry["auth"] == "bad":
                self.log(entry)
                return self.reply("authentication failure", 401)
        if replay is not None:
            return self.answer_from_replay(method, p, u.query, entry)
        self.log(entry)
        return self.answer_pilot(method, p, form)

    def answer_from_replay(self, method, p, query, entry):
        if method == "GET":
            for k in (p + "?" + query, p):
                if k in replay:
                    self.log(entry)
                    return self.reply(replay[k])
            if p.startswith("/nodes/hypervisor/tasks/"):   # only reached after a write
                self.log(entry)
                return self.task(p)
            entry["unknown"] = True
            self.log(entry)
            return self.reply(f"not in the replay: {p}?{query}", 501)
        self.log(entry)
        # PVE answers an LXC config PUT synchronously, everything else with a task
        return self.reply(None if method == "PUT" else UPID.format(t="smoke"))

    def task(self, p):
        if p.endswith("/status"):
            return self.reply({"status": "stopped", "exitstatus": "OK", "upid": urllib.parse.unquote(p.split("/")[4])})
        return self.reply([{"n": 1, "t": "TASK OK"}])

    def answer_pilot(self, method, p, form):
        if p == "/version":
            return self.reply({"version": "9.2.2", "release": "9.2", "repoid": "smoke"})
        if p == "/nodes":
            return self.reply([{"node": "hypervisor", "status": "online"}])
        if p.startswith("/nodes/hypervisor/tasks/"):
            return self.task(p)
        if p == "/nodes/hypervisor/lxc" and method == "POST":
            state["exists"] = True
            if form.get("start") in (["1"], "1", 1, True):
                state["running"] = True
            return self.reply(UPID.format(t="vzcreate"))
        if p == "/nodes/hypervisor/lxc" and method == "GET":
            return self.reply([{"vmid": 980, "status": "running" if state["running"] else "stopped", "name": "tofu-pilot"}] if state["exists"] else [])
        if p.startswith("/nodes/hypervisor/lxc/980"):
            if not state["exists"]:
                return self.reply("Configuration file 'nodes/hypervisor/lxc/980.conf' does not exist", 500)
            if p.endswith("/status/start") and method == "POST":
                state["running"] = True
                return self.reply(UPID.format(t="vzstart"))
            if (p.endswith("/status/shutdown") or p.endswith("/status/stop")) and method == "POST":
                state["running"] = False
                return self.reply(UPID.format(t="vzstop"))
            if p.endswith("/status/current"):
                return self.reply({"status": "running" if state["running"] else "stopped", "vmid": 980, "name": "tofu-pilot"})
            if p.endswith("/config") and method == "GET":
                return self.reply(CONF)
            if p.endswith("/config") and method in ("PUT", "POST"):
                return self.reply(None)
            if p.endswith("/interfaces"):
                return self.reply([])
            if p == "/nodes/hypervisor/lxc/980" and method == "DELETE":
                state["exists"] = state["running"] = False
                return self.reply(UPID.format(t="vzdestroy"))
        if p.startswith("/nodes/hypervisor/storage/") and "/content" in p:
            return self.reply([{"volid": "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst", "content": "vztmpl", "format": "tzst", "size": 129000000}])
        if p.startswith("/nodes/hypervisor/storage"):
            return self.reply([{"storage": "local-lvm", "type": "lvmthin", "content": "rootdir,images", "active": 1, "enabled": 1}])
        if p.startswith("/cluster/resources"):
            return self.reply([{"vmid": 980, "type": "lxc", "node": "hypervisor", "pool": "pilot"}] if state["exists"] else [])
        if p.startswith("/pools"):
            return self.reply({"members": []})
        return self.reply({})

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PUT(self): self.handle_any("PUT")
    def do_DELETE(self): self.handle_any("DELETE")


srv = ThreadingHTTPServer(("127.0.0.1", port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
