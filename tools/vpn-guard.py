#!/usr/bin/env python3
"""Kill switch for the guest's network: keep its link up only while the host's VPN is.

    tools/vpn-guard.py --qmp SOCKET [--netdev vnet0] [--interval 1]

run-vphone.sh starts this with REQUIRE_VPN=1. It waits for QEMU's QMP socket, then checks
every --interval seconds whether the host's default route goes through a VPN interface
(tools/surfshark.sh check) and sets the guest NIC's link down (set_link) when it does not,
up again when it does. iOS then sees its network cable unplugged, and the user-mode network
drops whatever the guest sends meanwhile, so nothing leaves outside the tunnel. It exits with
QEMU (the socket closes).
"""
import argparse
import json
import os
import select
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = [os.path.join(HERE, "surfshark.sh"), "check", "-q"]


def log(msg):
    print(f"vpn-guard: {msg}", file=sys.stderr, flush=True)


def vpn_up():
    try:
        return subprocess.run(CHECK, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


class QMP:
    def __init__(self, path, timeout):
        deadline = time.monotonic() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                self.sock.close()
                if time.monotonic() > deadline:
                    raise SystemExit(f"vpn-guard: no QMP socket at {path}")
                time.sleep(0.2)
        self.buf = self.sock.makefile("rb")
        self._read()                       # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        line = self.buf.readline()
        if not line:
            raise EOFError
        return json.loads(line)

    def cmd(self, command, **arguments):
        msg = {"execute": command}
        if arguments:
            msg["arguments"] = arguments
        self.sock.sendall(json.dumps(msg).encode() + b"\n")
        while True:
            reply = self._read()
            if "event" in reply:
                continue
            if "error" in reply:
                raise RuntimeError(reply["error"].get("desc", reply["error"]))
            return reply.get("return")

    def wait(self, seconds):
        """Sleep, but notice QEMU going away (EOFError) and drain its events meanwhile."""
        ready, _, _ = select.select([self.sock], [], [], seconds)
        if ready:
            self._read()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--netdev", default="vnet0")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--connect-timeout", type=float, default=120)
    args = ap.parse_args()

    qmp = QMP(args.qmp, args.connect_timeout)
    try:
        os.unlink(args.qmp)                # nobody else needs it; QEMU keeps the listener
    except OSError:
        pass
    link = None
    try:
        while True:
            up = vpn_up()
            if up != link:
                qmp.cmd("set_link", name=args.netdev, up=up)
                if link is not None or not up:
                    log("VPN " + ("back: guest network up" if up else "DOWN: guest network cut"))
                link = up
            qmp.wait(args.interval)
    except (EOFError, BrokenPipeError, ConnectionResetError):
        return 0                           # QEMU exited


if __name__ == "__main__":
    sys.exit(main())
