#!/usr/bin/env python3
"""Drives ./deltactl in a real pseudo-terminal, rebuilds the screen and measures what the panel costs.
Read-only against the real Docker: it only sends navigation keys and read-only commands (status, logs)."""
import fcntl, json, os, pty, select, shutil, signal, struct, subprocess, sys, termios, time

ROWS, COLS = 30, 110
CLK = os.sysconf("SC_CLK_TCK")
REPO = "/mnt/e/ITC/itc-deploy"
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pty-report.json"


class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.g = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.pending = b""

    def clear(self):
        self.g = [[" "] * self.cols for _ in range(self.rows)]

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
                if i + 1 < n and s[i + 1] == "[":
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
                    self.g[self.r][self.c] = ch
                self.c = min(self.c + 1, self.cols - 1)
            i += 1

    def csi(self, params, final):
        if final == "H":
            p = params.split(";")
            self.r = min(max(int(p[0] or 1) - 1, 0), self.rows - 1)
            self.c = min(max(int(p[1] or 1) - 1 if len(p) > 1 else 0, 0), self.cols - 1)
        elif final == "K":
            for k in range(self.c, self.cols):
                self.g[self.r][k] = " "
        elif final == "J":
            if params in ("2", "3"):
                self.clear()
            else:
                for k in range(self.c, self.cols):
                    self.g[self.r][k] = " "
                for rr in range(self.r + 1, self.rows):
                    self.g[rr] = [" "] * self.cols

    def text(self):
        return "\n".join("".join(row).rstrip() for row in self.g).rstrip("\n")


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True, **kw).stdout


def prep(name, kind):
    dst = f"/tmp/dctl-{name}"
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst + "/instances")
    if kind == "new":
        for p in ("deltactl", "lib", "templates", "services", "examples", "compose.yaml"):
            sh(f"cp -r {REPO}/{p} {dst}/")
    else:
        sh(f"git -c safe.directory='*' -C {REPO} archive develop | tar -x -C {dst}")
    sh(f"find {dst} -name '*.sh' -o -name deltactl | xargs sed -i 's/\\r$//'")
    os.makedirs(dst + "/instances/colorado")
    sh(f"cp -p {REPO}/instances/colorado/.[a-z]* {dst}/instances/colorado/")
    sh(f"touch {dst}/instances/.gitkeep")
    return dst


def ticks(pid):
    s = open(f"/proc/{pid}/stat").read()
    rest = s[s.rfind(")") + 2 :].split()
    u, st, cu, cs = (int(x) for x in rest[11:15])
    return u + st, cu + cs


def rss_kb(pid):
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0


def children(pid):
    try:
        return sh(f"ps --ppid {pid} -o comm= | sort | uniq -c").split("\n")
    except Exception:
        return []


def spawn(cwd, extra_env, shim=None):
    env = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8", DELTACTL_CONFIG=f"{cwd}/.cfg-absent")
    env.update(extra_env)
    if shim:
        env["PATH"] = shim + ":" + env["PATH"]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execvpe("bash", ["bash", "./deltactl"], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    return pid, fd


def pump(fd, screen, secs):
    end = time.time() + secs
    while True:
        t = end - time.time()
        if t <= 0:
            return True
        r, _, _ = select.select([fd], [], [], min(t, 0.05))
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            screen.feed(data)


def type_text(fd, screen, text, delay=0.02):
    for ch in text:
        os.write(fd, ch.encode())
        pump(fd, screen, delay)


def stop(pid, fd, screen):
    try:
        os.write(fd, b"q")
    except OSError:
        pass
    pump(fd, screen, 1.0)
    end = time.time() + 3
    while time.time() < end:
        done, _ = os.waitpid(pid, os.WNOHANG)
        if done:
            return True
        time.sleep(0.05)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    return False


def scenario(name, cwd, script, extra_env=None, shim=None, startup=3.0):
    """script(fd, screen, snap) drives the keys; returns a dict with the measurements."""
    screen = Screen(ROWS, COLS)
    t_spawn = time.time()
    pid, fd = spawn(cwd, extra_env or {}, shim)
    first = None
    end = time.time() + startup
    while time.time() < end:
        pump(fd, screen, 0.02)
        if first is None and "Instancias" in screen.text() or first is None and "Instances" in screen.text():
            first = time.time() - t_spawn
    snaps = {}

    def snap(label):
        snaps[label] = screen.text()

    snap("start")
    own0, kids0 = ticks(pid)
    t0 = time.time()
    script(fd, screen, snap)
    t1 = time.time()
    own1, kids1 = ticks(pid)
    kids = children(pid)
    res = {
        "name": name,
        "seconds": round(t1 - t0, 1),
        "first_frame_s": round(first, 2) if first else None,
        "cpu_own_pct": round((own1 - own0) / CLK / (t1 - t0) * 100, 2),
        "cpu_children_pct": round((kids1 - kids0) / CLK / (t1 - t0) * 100, 2),
        "cpu_total_pct": round((own1 + kids1 - own0 - kids0) / CLK / (t1 - t0) * 100, 2),
        "rss_mb": round(rss_kb(pid) / 1024, 1),
        "children": [k.strip() for k in kids if k.strip()],
        "exited_cleanly": None,
        "snaps": snaps,
    }
    res["exited_cleanly"] = stop(pid, fd, screen)
    return res


def idle(secs):
    return lambda fd, screen, snap: pump(fd, screen, secs)


def nav(fd, screen, snap):
    """Holds the down key for a while, then walks the three views, then opens the help."""
    pump(fd, screen, 1)
    for _ in range(150):
        os.write(fd, b"j")
        pump(fd, screen, 0.02)
    for k in (b"2", b"s", b"s", b"s", b"3", b"1", b"\t", b"\t", b"\t"):
        os.write(fd, k)
        pump(fd, screen, 0.3)
        snap("after_" + repr(k))
    os.write(fd, b"?")
    pump(fd, screen, 0.5)
    snap("help")
    os.write(fd, b"x")
    pump(fd, screen, 0.3)


def views(fd, screen, snap):
    pump(fd, screen, 5)
    snap("instances_after_5s")
    os.write(fd, b"2")
    pump(fd, screen, 2.5)
    snap("resources")
    os.write(fd, b"1")
    pump(fd, screen, 0.5)
    os.write(fd, b"\r")
    pump(fd, screen, 0.5)
    snap("actions_menu")
    os.write(fd, b"\x1b")
    pump(fd, screen, 0.5)
    os.write(fd, b":")
    type_text(fd, screen, "status colorado")
    pump(fd, screen, 0.3)
    snap("command_line")
    os.write(fd, b"\r")
    pump(fd, screen, 4)
    snap("status_output")
    os.write(fd, b"1")
    pump(fd, screen, 1)


def logs_job(secs):
    def run(fd, screen, snap):
        pump(fd, screen, 0.5)
        os.write(fd, b":")
        type_text(fd, screen, "logs colorado s0 -f")
        os.write(fd, b"\r")
        pump(fd, screen, secs)
        snap("logs_running")
        os.write(fd, b"x")
        pump(fd, screen, 3)
        snap("logs_cancelled")

    return run


def make_shim(name):
    d = f"/tmp/dctl-shim-{name}"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    log = f"{d}/calls.log"
    open(d + "/docker", "w").write(f'#!/bin/sh\necho "$1 $2" >> {log}\nexec /usr/bin/docker "$@"\n')
    os.chmod(d + "/docker", 0o755)
    return d, log


def count_calls(log):
    try:
        lines = [l.strip() for l in open(log)]
    except FileNotFoundError:
        return {}
    out = {}
    for l in lines:
        k = l.split()[0] if l else "?"
        out[k] = out.get(k, 0) + 1
    out["_total"] = len(lines)
    return out


def main():
    new = prep("new", "new")
    if len(sys.argv) > 2 and sys.argv[2] == "idle":
        old = prep("old", "old")
        report = {"rows": ROWS, "cols": COLS, "results": []}
        report["results"].append(scenario("new: idle 60 s", new, idle(60)))
        report["results"].append(scenario("old (develop before the panel): idle 60 s", old, idle(60)))
        report["results"].append(scenario("new: following live logs for 25 s", new, logs_job(25)))
        for label, d in (("new", new), ("old", old)):
            shim, log = make_shim(label)
            scenario(f"{label}: docker calls", d, idle(30), shim=shim)
            report[f"docker_calls_30s_{label}"] = count_calls(log)
        json.dump(report, open(OUT, "w"), indent=1, ensure_ascii=False)
        print("written", OUT)
        return
    if len(sys.argv) > 2 and sys.argv[2] == "quick":
        r = scenario("quick", new, views)
        for k, v in r["snaps"].items():
            print("=====", k); print(v)
        print({x: r[x] for x in r if x != "snaps"})
        return
    old = prep("old", "old")
    report = {"rows": ROWS, "cols": COLS, "results": []}

    # Views and keys on the new panel (also checks the real cgroup metrics and the real Docker events)
    report["results"].append(scenario("new: views, actions menu and command line", new, views))
    report["results"].append(scenario("new: idle 60 s", new, idle(60)))
    report["results"].append(scenario("old (develop): idle 60 s", old, idle(60)))
    report["results"].append(scenario("new: 150 key presses + view switching", new, nav))
    report["results"].append(scenario("new: following live logs for 25 s", new, logs_job(25)))

    # How many docker calls each one makes (30 s idle through a counting shim)
    for label, d in (("new", new), ("old", old)):
        shim, log = make_shim(label)
        scenario(f"{label}: docker calls", d, idle(30), shim=shim)
        report[f"docker_calls_30s_{label}"] = count_calls(log)

    json.dump(report, open(OUT, "w"), indent=1, ensure_ascii=False)
    print("written", OUT)


if __name__ == "__main__":
    main()
