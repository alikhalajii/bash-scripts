#!/usr/bin/env python3
"""pty_drive.py - Answer the Docker picker on a pseudo-terminal, like a person would.

Purpose:  run CMD with a pty as its terminal, wait for "Remove which?", pick the numbered
          lines whose name is one of --pick, check that the confirmation repeats exactly
          those, then answer --confirm (y, n, or none = let the question time out).
Provides: exit 0 when every check passed and CMD exited 0; else a message and exit 1.
Example:  pty_drive.py --marker e2e/m-1:1 --pick e2e/a:1,gone --confirm y -- bash -c '...'
          (used by tests/e2e/docker-dind.sh; standard library only)
"""

import argparse
import os
import pty
import re
import select
import sys
import time

WAIT = 30  # seconds to wait for each prompt
ITEM = re.compile(r"^\s*(\d+)  .{6}  .{10}  (.*)$")


def fail(msg, out):
    sys.stdout.write(out)
    sys.stderr.write(f"pty_drive: {msg}\n")
    sys.exit(1)


def name_of(text):
    """First word of an item's text: 'e2e/a:1, e2e/a:latest' -> 'e2e/a:1'."""
    return re.split(r"[ ,]", text, maxsplit=1)[0]


class Child:
    def __init__(self, cmd):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvp(cmd[0], cmd)
        self.out = ""

    def read_until(self, pattern, timeout=WAIT):
        """Read until pattern appears after the current output; None on EOF or timeout."""
        start = len(self.out)
        end = time.monotonic() + timeout
        while pattern not in self.out[start:]:
            left = end - time.monotonic()
            if left <= 0:
                return None
            ready, _, _ = select.select([self.fd], [], [], left)
            if not ready:
                return None
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                return None
            if not data:
                return None
            self.out += data.decode("ascii", "replace").replace("\r", "")
        return self.out[start:]

    def send(self, text):
        os.write(self.fd, text.encode("ascii"))

    def wait(self):
        self.read_until("\0__never__", timeout=WAIT)  # drain until EOF
        _, status = os.waitpid(self.pid, 0)
        return os.waitstatus_to_exitcode(status)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pick", default="", help="comma-separated names; empty = no answer")
    ap.add_argument("--confirm", choices=["y", "n", "none"], required=True)
    ap.add_argument("--marker", required=True, help="an image that must be listed")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
    picks = [p for p in args.pick.split(",") if p]

    child = Child(cmd)
    listing = child.read_until("Remove which?")
    if listing is None:
        fail("no picker question", child.out)
    items = {}
    for line in listing.splitlines():
        m = ITEM.match(line)
        if m:
            items.setdefault(name_of(m.group(2)), []).append(m.group(1))
    if args.marker not in items:
        fail(f"marker {args.marker} not listed: not the test daemon?", child.out)

    if not picks:
        if child.read_until("No answer; nothing removed.") is None:
            fail("no 'No answer' after an unanswered picker", child.out)
    else:
        numbers = []
        for p in picks:
            if len(items.get(p, [])) != 1:
                fail(f"expected exactly one listed item named {p}", child.out)
            numbers.append(items[p][0])
        child.send(" ".join(numbers) + "\n")
        confirm = child.read_until("[y/N]")
        if confirm is None:
            fail("no confirmation question", child.out)
        repeated = {name_of(m.group(2)) for m in map(ITEM.match, confirm.splitlines()) if m}
        if repeated != set(picks):
            fail(f"confirmation lists {sorted(repeated)}, picked {sorted(picks)}", child.out)
        if args.confirm == "none":
            expect = "No answer; nothing removed."
        else:
            child.send(args.confirm + "\n")
            expect = "Nothing removed." if args.confirm == "n" else f"Docker: removed {len(picks)} of {len(picks)} item(s)"
        if child.read_until(expect) is None:
            fail(f"expected '{expect}'", child.out)

    rc = child.wait()
    sys.stdout.write(child.out)
    if rc != 0:
        fail(f"command exited {rc}", "")


if __name__ == "__main__":
    main()
