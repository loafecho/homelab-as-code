#!/usr/bin/env python3
"""Run a command in a pty the way an operator does over `ssh -t`, answering any
>>> prompt it prints. The "unplug"/"plug back" prompts swap a wrong age key in
for the stand-in YubiKey and back. Used by the smoke tests only; never for a
real run."""
import os
import pty
import select
import shutil
import sys
import time

scratch, cmd = sys.argv[1], sys.argv[2:]
key = os.path.join(scratch, "repo/keys/smoke-identity.txt")
wrong = os.path.join(scratch, "wrong-identity.txt")
held = os.path.join(scratch, "held-identity.txt")


def unplug():
    os.replace(key, held)
    shutil.copy(wrong, key)


def replug():
    os.replace(held, key)


# prompt fragment -> what to do before pressing Enter
PROMPTS = [("UNPLUG the YubiKey", unplug), ("PLUG the YubiKey back", replug),
           ("destroy CT 980", None)]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
seen, out, deadline = set(), b"", time.time() + 900
while time.time() < deadline:
    if select.select([fd], [], [], 0.5)[0]:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        sys.stdout.buffer.write(chunk)
        sys.stdout.flush()
        out += chunk
    text = out.decode(errors="replace")
    for frag, action in PROMPTS:
        if frag in text and frag not in seen:
            seen.add(frag)
            if action:
                action()
            time.sleep(0.5)
            os.write(fd, b"\r")
else:
    print("DRIVER: timed out")
    os.kill(pid, 9)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
