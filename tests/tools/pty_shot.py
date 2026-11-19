#!/usr/bin/env python3
"""Runs ./deltactl in a real pseudo-terminal of ROWS x COLS, optionally sends keys, and writes the screen WITH colours as JSON
(tests/tools/render_shot.ps1 turns it into a PNG, so a change of the interface can be looked at, not only measured).

usage: pty_shot.py OUT.json ROWS COLS [step ...]
  steps: sleep:SECONDS | key:CHAR | text:STRING | enter | esc | up | down | left | right | tab
  environment passed through: DELTACTL_THEME, DELTACTL_TRUECOLOR, COLORTERM, WT_SESSION, DELTACTL_LANG
Read-only against the real Docker (status and metrics); it never changes an instance unless the steps run a command yourself."""
import fcntl, json, os, pty, select, struct, subprocess, sys, termios, time

REPO = "/mnt/e/ITC/itc-deploy"
D = "/tmp/dctl-shot"

BASE16 = [(0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
          (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)]


def xterm256(n):
    if n < 16:
        return BASE16[n]
    if n >= 232:
        v = 8 + (n - 232) * 10
        return (v, v, v)
    n -= 16
    lv = [0, 95, 135, 175, 215, 255]
    return (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])


class Screen:
    """A small terminal emulator: cursor moves, erase, SGR colours (16, 256 and 24-bit), bold, dim and reverse."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.cur = (None, None, 0)  # fg, bg, flags (1 bold, 2 dim, 4 reverse)
        self.g = [[(" ", None, None, 0)] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.pending = b""

    def blank(self):
        return (" ", self.cur[0], self.cur[1], 0)

    def feed(self, data):
        self.pending += data
        try:
            s = self.pending.decode("utf-8")
            self.pending = b""
        except UnicodeDecodeError as e:
            s = self.pending[: e.start].decode("utf-8", "ignore")
            self.pending = self.pending[e.start:]
        i, n = 0, len(s)
        while i < n:
            ch = s[i]
            if ch == "\x1b":
                if i + 1 >= n:  # the read ended right after ESC: wait for the rest of the sequence
                    self.pending = s[i:].encode() + self.pending
                    return
                if s[i + 1] == "[":
                    j = i + 2
                    while j < n and not ("@" <= s[j] <= "~"):
                        j += 1
                    if j >= n:
                        self.pending = s[i:].encode() + self.pending
                        return
                    self.csi(s[i + 2 : j], s[j])
                    i = j + 1
                    continue
                i += 2
                continue
            if ch == "\r":
                self.c = 0
            elif ch == "\n":
                self.r = min(self.r + 1, self.rows - 1)
            elif ch >= " ":
                if self.r < self.rows and self.c < self.cols:
                    self.g[self.r][self.c] = (ch, self.cur[0], self.cur[1], self.cur[2])
                self.c = min(self.c + 1, self.cols - 1)
            i += 1

    def sgr(self, params):
        ps = [int(x) if x.isdigit() else 0 for x in params.split(";")] if params else [0]
        fg, bg, fl = self.cur
        i = 0
        while i < len(ps):
            p = ps[i]
            if p == 0:
                fg, bg, fl = None, None, 0
            elif p == 1:
                fl |= 1
            elif p == 2:
                fl |= 2
            elif p == 7:
                fl |= 4
            elif p in (22,):
                fl &= ~3
            elif p == 27:
                fl &= ~4
            elif 30 <= p <= 37:
                fg = BASE16[p - 30]
            elif 90 <= p <= 97:
                fg = BASE16[p - 90 + 8]
            elif 40 <= p <= 47:
                bg = BASE16[p - 40]
            elif 100 <= p <= 107:
                bg = BASE16[p - 100 + 8]
            elif p == 39:
                fg = None
            elif p == 49:
                bg = None
            elif p in (38, 48):
                if i + 1 < len(ps) and ps[i + 1] == 2 and i + 4 < len(ps):
                    col = (ps[i + 2], ps[i + 3], ps[i + 4])
                    i += 4
                elif i + 1 < len(ps) and ps[i + 1] == 5 and i + 2 < len(ps):
                    col = xterm256(ps[i + 2])
                    i += 2
                else:
                    col = None
                if p == 38:
                    fg = col
                else:
                    bg = col
            i += 1
        self.cur = (fg, bg, fl)

    def csi(self, params, final):
        if final == "m":
            self.sgr(params)
        elif final == "H":
            p = params.split(";")
            self.r = min(max(int(p[0] or 1) - 1, 0), self.rows - 1)
            self.c = min(max(int(p[1] or 1) - 1 if len(p) > 1 and p[1] else 0, 0), self.cols - 1)
        elif final == "K":
            for k in range(self.c, self.cols):
                self.g[self.r][k] = self.blank()
        elif final == "J" and params in ("2", "3"):
            self.g = [[self.blank()] * self.cols for _ in range(self.rows)]

    def dump(self):
        rows = []
        for row in self.g:
            out = []
            for ch, fg, bg, fl in row:
                out.append([ch, list(fg) if fg else None, list(bg) if bg else None, fl])
            rows.append(out)
        return rows


def pump(fd, screen, secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                screen.feed(os.read(fd, 65536))
            except OSError:
                return


KEYS = {"enter": b"\r", "esc": b"\x1b", "up": b"\x1b[A", "down": b"\x1b[B", "right": b"\x1b[C", "left": b"\x1b[D", "tab": b"\t"}


def main():
    out, rows, cols = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    steps = sys.argv[4:] or ["sleep:4"]
    subprocess.run(
        f"rm -rf {D}; mkdir -p {D}/instances/colorado; cd {REPO} && cp -r deltactl lib templates services examples compose.yaml {D}/ "
        f"&& cp -p instances/colorado/.[a-z]* {D}/instances/colorado/ 2>/dev/null; touch {D}/instances/.gitkeep; "
        f"find {D} -name '*.sh' -o -name deltactl | xargs sed -i 's/\\r$//'", shell=True, check=True)
    env = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8", DELTACTL_CONFIG=D + "/.cfg-absent")
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(D)
        os.execvpe("bash", ["bash", "./deltactl"], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    screen = Screen(rows, cols)
    for st in steps:
        if st.startswith("sleep:"):
            pump(fd, screen, float(st[6:]))
        elif st.startswith("key:"):
            os.write(fd, st[4:].encode()); pump(fd, screen, 0.4)
        elif st.startswith("text:"):
            for ch in st[5:]:
                os.write(fd, ch.encode()); time.sleep(0.02)
            pump(fd, screen, 0.3)
        elif st in KEYS:
            os.write(fd, KEYS[st]); pump(fd, screen, 0.5)
    json.dump({"rows": rows, "cols": cols, "cells": screen.dump()}, open(out, "w"))
    os.write(fd, b"q")
    time.sleep(0.5)
    print("saved", out)


if __name__ == "__main__":
    main()
