#!/usr/bin/env python3
"""Runs the panel in a real pseudo-terminal over a matrix of terminals and checks what a test mode cannot see.

Self-contained and harmless: it copies the repository to a temporary folder, builds a simulated Docker there (a shim on the PATH,
twelve fake instances, fake cgroups) and never talks to the real Docker. For every configuration (TERM, colours, locale, size,
mouse) it checks that:
  - the panel starts (or, where it cannot, prints the text home screen and ends by itself, as with TERM=dumb);
  - nothing is drawn past the right edge of the screen (the panel turns autowrap off, so an overflow would overwrite the last
    column: the emulator below counts those writes);
  - it redraws after a resize (SIGWINCH) to the new size;
  - on the way out the terminal is left as it was found: alternate screen left, cursor shown, mouse reporting off, echo and
    canonical mode back on;
  - it exits with status 0 and leaves no process of its own behind (it runs under a wrapper that stays the leader of the
    terminal's session, as the user's shell would, so a leftover child is not killed by the hangup and can be seen);
It also measures the CPU the panel uses while idle in each view: its own and that of the processes it starts.

usage: tests/tools/pty_matrix.py [report.json]      (needs python3 and bash; takes about three minutes)
"""
import codecs, fcntl, json, os, select, shutil, signal, struct, subprocess, sys, tempfile, termios, time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLK = os.sysconf("SC_CLK_TCK")
OUT = sys.argv[1] if len(sys.argv) > 1 else None


class Screen:
    """A small VT emulator: enough of CSI to rebuild the panel's screen, with autowrap off like the panel sets it."""

    def __init__(self, rows, cols):
        self.resize(rows, cols)
        # (a byte that is not UTF-8 becomes U+FFFD and the rest goes on being read: a stuck decoder would stop the checks)
        self.dec = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.pending = ""
        self.overflow = 0

    def resize(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.g = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.edge = False  # the last write landed in the last column

    def feed(self, data):
        s = self.pending + self.dec.decode(data)
        self.pending = ""
        i, n = 0, len(s)
        while i < n:
            ch = s[i]
            if ch == "\x1b":
                if i + 1 >= n:  # the read ended right after ESC: wait for the rest of the sequence
                    self.pending = s[i:]
                    return
                if s[i + 1] == "[":
                    j = i + 2
                    while j < n and not ("@" <= s[j] <= "~"):
                        j += 1
                    if j >= n:
                        self.pending = s[i:]
                        return
                    self.csi(s[i + 2 : j], s[j])
                    i = j + 1
                    continue
                i += 2
                continue
            if ch == "\r":
                self.c, self.edge = 0, False
            elif ch == "\n":
                self.r, self.edge = min(self.r + 1, self.rows - 1), False
            elif ch >= " ":
                if self.edge:
                    self.overflow += 1  # a character past the right edge: without autowrap it overwrites the last column
                if self.r < self.rows:
                    self.g[self.r][self.c] = ch
                if self.c >= self.cols - 1:
                    self.edge = True
                else:
                    self.c += 1
            i += 1

    def csi(self, params, final):
        p = [int(x) if x.isdigit() else 0 for x in params.lstrip("?").split(";")] if params else []
        if final == "H":
            r = (p[0] if p and p[0] else 1) - 1
            c = (p[1] if len(p) > 1 and p[1] else 1) - 1
            self.r, self.c, self.edge = min(r, self.rows - 1), min(c, self.cols - 1), False
        elif final == "J" and (not p or p[0] in (2, 3)):
            self.g = [[" "] * self.cols for _ in range(self.rows)]
        elif final == "K":
            for c in range(self.c, self.cols):
                self.g[self.r][c] = " "

    def text(self):
        return "\n".join("".join(row).rstrip() for row in self.g)

    def row(self, r):
        return "".join(self.g[r])


def sh(cmd, **kw):
    return subprocess.run(["bash", "-c", cmd], check=True, capture_output=True, text=True, **kw).stdout


def build_fixture(base):
    """A copy of the repository with a simulated Docker and twelve instances (two in three running)."""
    d = os.path.join(base, "repo")
    os.makedirs(os.path.join(d, "instances"))
    for p in ("deltactl", "lib", "templates", "services", "compose.yaml", "tests"):
        src = os.path.join(REPO, p)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(d, p))
        elif os.path.exists(src):
            shutil.copy2(src, d)
    fix = os.path.join(base, "fix")
    os.makedirs(os.path.join(fix, "bin"))
    shutil.copy2(os.path.join(REPO, "tests", "fake-docker.sh"), os.path.join(fix, "bin", "docker-fake"))
    with open(os.path.join(fix, "bin", "docker"), "w") as f:
        f.write("""#!/usr/bin/env bash
case "$1" in
  ps) n=$(wc -l < "$FIX/containers.txt"); for ((i = 1; i <= n; i++)); do echo "c$i"; done ;;
  inspect) cat "$FIX/containers.txt" ;;
  stats) : ;;
  logs) echo "linea normal"; echo "ERROR de prueba"; case "$*" in *" -f "*) exec sleep 600 ;; esac ;;
  compose) case "$*" in *" logs"*) echo "linea normal" ;; *) exec bash "$FIX/bin/docker-fake" "$@" ;; esac ;;
  events) exec sleep 600 ;;
  *) exec bash "$FIX/bin/docker-fake" "$@" ;;
esac
""")
    with open(os.path.join(fix, "bin", "ss"), "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    for b in ("docker", "ss"):
        os.chmod(os.path.join(fix, "bin", b), 0o755)
    for name in ("containers.txt", "images.txt", "stats.txt"):
        open(os.path.join(fix, name), "w").close()
    with open(os.path.join(fix, "meminfo"), "w") as f:
        f.write("MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n")
    with open(os.path.join(fix, "loadavg"), "w") as f:
        f.write("0.82 0.50 0.40 1/200 1234\n")
    sh(r"""
set -e
export PATH="$FIX/bin:$PATH" DELTACTL_CONFIG="$PWD/.cfg" DELTACTL_TEST_ISOLATED=1
source tests/lib.sh >/dev/null
s2="$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S.000000000Z)"
for i in $(seq 1 12); do
  inst="$(printf 'pty-%02d' "$i")"
  bash ./deltactl new "$inst" >/dev/null 2>&1
  fill_instance "instances/$inst" 1.0 1.0
  if [ $((i % 3)) -ne 2 ]; then
    for s in 0 1; do
      pid=$((3000 + i * 2 + s))
      printf '%s|s%s|running|healthy|img:1.0|%s|/s%s_%s|%s|0\n' "$inst" "$s" "$s2" "$s" "$inst" "$pid" >> "$FIX/containers.txt"
      mkdir -p "$FIX/proc/$pid" "$FIX/cg/scope-$pid"
      echo "0::/scope-$pid" > "$FIX/proc/$pid/cgroup"
      echo $((pid * 40000)) > "$FIX/cg/scope-$pid/memory.current"; echo max > "$FIX/cg/scope-$pid/memory.max"
      printf 'usage_usec %s\n' $((pid * 1000)) > "$FIX/cg/scope-$pid/cpu.stat"
    done
  fi
done
""", cwd=d, env=dict(os.environ, FIX=fix, HOME=base, XDG_CONFIG_HOME=os.path.join(base, "xdg")))
    return d, fix


def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def spawn(repo, fix, cfgdir, rows, cols, env_extra):
    master, slave = os.openpty()
    set_size(slave, rows, cols)
    env = {
        "PATH": os.path.join(fix, "bin") + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": cfgdir, "TERM": "xterm-256color", "LANG": "C.UTF-8", "FIX": fix,
        "DELTACTL_CONFIG": os.path.join(cfgdir, "config"), "DELTACTL_LANG": "es",
        "DELTACTL_MEMINFO": os.path.join(fix, "meminfo"), "DELTACTL_LOADAVG": os.path.join(fix, "loadavg"),
        "DELTACTL_PROC_ROOT": os.path.join(fix, "proc"), "DELTACTL_CGROUP_ROOT": os.path.join(fix, "cg"),
    }
    env.update(env_extra)
    env = {k: v for k, v in env.items() if v is not None}
    # The wrapper is the leader of the terminal's session, like the user's shell: when the panel ends nothing is killed by a
    # hangup, so what it leaves behind can be seen. It prints the panel's exit status and waits to be ended.
    wrapper = 'bash ./deltactl; echo "__rc=$?"; exec sleep 60'
    p = subprocess.Popen(["bash", "-c", wrapper], cwd=repo, env=env, stdin=slave, stdout=slave, stderr=slave,
                         start_new_session=True, preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    return p, master, slave


def session_procs(sid):
    """Processes of a session, as (pid, ppid, command name)."""
    out = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/stat") as f:
                raw = f.read()
        except OSError:
            continue
        comm = raw[raw.index("(") + 1 : raw.rindex(")")]
        st = raw.rsplit(")", 1)[1].split()
        if int(st[3]) == sid:
            out.append((int(d), int(st[1]), comm))
    return out


def panel_pid(sid, wrapper):
    """The panel: the bash child of the wrapper."""
    for pid, ppid, comm in session_procs(sid):
        if ppid == wrapper and comm == "bash":
            return pid
    return None


def pump(fd, scr, secs, raw):
    end = time.time() + secs
    while True:
        left = end - time.time()
        if left <= 0:
            return
        r, _, _ = select.select([fd], [], [], left)
        if not r:
            return
        try:
            data = os.read(fd, 65536)
        except OSError:
            return
        if not data:
            return
        raw.append(data)
        scr.feed(data)


def cpu_ticks(pid):
    """(own ticks, ticks of the children it has waited for)"""
    with open(f"/proc/{pid}/stat") as f:
        st = f.read().rsplit(")", 1)[1].split()
    return int(st[11]) + int(st[12]), int(st[13]) + int(st[14])


def run(repo, fix, name, rows, cols, env=None, keys=(), resize=None, mouse=False, expect_panel=True, idle_views=False):
    cfgdir = tempfile.mkdtemp(prefix="cfg-")
    if mouse:
        with open(os.path.join(cfgdir, "config"), "w") as f:
            f.write("TUI_MOUSE=on\n")
    scr, raw = Screen(rows, cols), []
    p, fd, slave = spawn(repo, fix, cfgdir, rows, cols, env or {})
    res = {"name": name, "size": f"{cols}x{rows}", "checks": {}, "notes": []}
    chk = res["checks"]
    try:
        pump(fd, scr, 4.0, raw)
        first = scr.text()
        if not expect_panel:
            pump(fd, scr, 2.0, raw)
            out = b"".join(raw)
            chk["falls back to the text home and ends by itself"] = b"__rc=" in out and b"\x1b[?1049h" not in out
            chk["exit status 0"] = b"__rc=0" in out
            return res
        chk["starts and draws the panel"] = "Instancias" in first and "Consola" in first
        attrs = termios.tcgetattr(slave)
        chk["echo is off while it runs"] = not (attrs[3] & termios.ECHO)
        if mouse:
            chk["mouse reporting turned on"] = b"\x1b[?1000h\x1b[?1006h" in b"".join(raw)
        for k in keys:
            os.write(fd, k.encode() if isinstance(k, str) else k)
            pump(fd, scr, 0.8, raw)
        if mouse:
            # A click on the tab of the Output view (3), column 33 of row 2: the list of instances must give way to that view.
            before = scr.row(2)
            os.write(fd, b"\x1b[<0;33;2M\x1b[<0;33;2m")
            pump(fd, scr, 1.0, raw)
            chk["a click on a tab opens its view"] = "Instancias" in before and "Instancias" not in scr.row(2)
            os.write(fd, b"1")
            pump(fd, scr, 0.8, raw)
        if resize:
            nr, nc = resize
            set_size(slave, nr, nc)
            scr.resize(nr, nc)
            os.killpg(p.pid, signal.SIGWINCH)
            pump(fd, scr, 2.5, raw)
            # The boxes reach the new right edge and the key bar is on the new last row.
            chk[f"redraws at the new size ({nc}x{nr})"] = (
                "Instancias" in scr.text() and scr.row(2)[nc - 1] != " " and "salir" in scr.row(nr - 1)
            )
        if idle_views:
            res["idle_cpu_pct"], res["idle_cpu_children_pct"] = {}, {}
            pp = panel_pid(p.pid, p.pid)
            for key, view in (("1", "Instancias"), ("2", "Recursos"), ("3", "Salida"), ("4", "Ejecuciones"), ("5", "Procesos")):
                os.write(fd, key.encode())
                pump(fd, scr, 3.0, raw)
                t0, (o0, c0) = time.time(), cpu_ticks(pp)
                pump(fd, scr, 12.0, raw)
                t1, (o1, c1) = time.time(), cpu_ticks(pp)
                res["idle_cpu_pct"][view] = round((o1 - o0) / CLK / (t1 - t0) * 100, 2)
                res["idle_cpu_children_pct"][view] = round((c1 - c0) / CLK / (t1 - t0) * 100, 2)
            os.write(fd, b"1")
            pump(fd, scr, 1.0, raw)
        chk["nothing is drawn past the right edge"] = scr.overflow == 0
        if scr.overflow:
            res["notes"].append(f"{scr.overflow} characters past the right edge")
        os.write(fd, b"q")
        end = time.time() + 10
        while time.time() < end and b"__rc=" not in b"".join(raw):
            pump(fd, scr, 0.5, raw)
        out = b"".join(raw)
        tail = out[-500:]
        chk["exit status 0"] = b"__rc=0" in out
        chk["leaves the alternate screen and shows the cursor"] = b"\x1b[?1049l" in tail and b"\x1b[?25h" in tail
        chk["turns mouse reporting off"] = b"\x1b[?1006l\x1b[?1000l" in tail
        attrs = termios.tcgetattr(slave)
        chk["echo and canonical mode are back"] = bool(attrs[3] & termios.ECHO) and bool(attrs[3] & termios.ICANON)
        left = [f"{c} ({pid})" for pid, ppid, c in session_procs(p.pid) if pid != p.pid]
        chk["leaves no process behind"] = not left
        if left:
            res["notes"].append("left behind: " + ", ".join(left))
        return res
    finally:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()
        os.close(fd)
        os.close(slave)
        shutil.rmtree(cfgdir, ignore_errors=True)


def main():
    base = tempfile.mkdtemp(prefix="pty-matrix-")
    try:
        repo, fix = build_fixture(base)
        nav = ["2", "3", "4", "5", "6", "\x1b", "1", "\t", "\t", "?", "x", "o", "\x1b"]
        cases = [
            dict(name="xterm-256color, UTF-8, resized twice", rows=30, cols=120, keys=nav, resize=(24, 80)),
            dict(name="xterm-256color, UTF-8, wide", rows=55, cols=200, keys=nav, resize=(40, 160)),
            dict(name="xterm (16 colours)", rows=30, cols=100, env={"TERM": "xterm"}, keys=nav),
            dict(name="screen-256color (tmux/screen)", rows=30, cols=100, env={"TERM": "screen-256color"}, keys=nav),
            dict(name="linux console, LANG=C (ASCII)", rows=25, cols=80, env={"TERM": "linux", "LANG": "C"}, keys=nav),
            dict(name="vt100, LANG=C", rows=24, cols=80, env={"TERM": "vt100", "LANG": "C"}, keys=nav),
            dict(name="NO_COLOR=1", rows=30, cols=100, env={"NO_COLOR": "1"}, keys=nav, expect_panel=None),
            dict(name="truecolor + mouse on", rows=40, cols=160, env={"COLORTERM": "truecolor"}, keys=nav, mouse=True),
            dict(name="smallest supported (60x14)", rows=14, cols=60, keys=nav),
            dict(name="TERM=dumb", rows=24, cols=80, env={"TERM": "dumb"}, expect_panel=False),
            dict(name="idle CPU per view (120x30, 12 instances)", rows=30, cols=120, idle_views=True),
        ]
        results = []
        for c in cases:
            exp = c.pop("expect_panel", True)
            if exp is None:
                # NO_COLOR: either the panel runs without colours or it declines and shows the text home; both are fine.
                r = run(repo, fix, expect_panel=True, **c)
                if not r["checks"].get("starts and draws the panel"):
                    r = run(repo, fix, expect_panel=False, **c)
                    r["notes"].append("the panel declined without colours and showed the text home")
            else:
                r = run(repo, fix, expect_panel=exp, **c)
            results.append(r)
            ok = all(r["checks"].values())
            print(f"{'OK  ' if ok else 'FAIL'} {r['name']} ({r['size']})")
            for k, v in r["checks"].items():
                if not v:
                    print(f"       failed: {k}")
            for note in r["notes"]:
                print(f"       note: {note}")
            if "idle_cpu_pct" in r:
                print("       idle CPU of the panel itself: " + ", ".join(f"{k} {v} %" for k, v in r["idle_cpu_pct"].items()))
                print("       and of what it starts:        " + ", ".join(f"{k} {v} %" for k, v in r["idle_cpu_children_pct"].items()))
        if OUT:
            with open(OUT, "w") as f:
                json.dump(results, f, indent=2, ensure_ascii=False)
        sys.exit(0 if all(all(r["checks"].values()) for r in results) else 1)
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    main()
