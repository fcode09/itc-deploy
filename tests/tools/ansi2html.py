#!/usr/bin/env python3
"""Turns text with ANSI colour sequences (SGR: 0 1 2 4 7, 30-37, 90-97, 38/48 with 5;n or 2;r;g;b, 39, 49) into one HTML page
with a dark terminal background, so a screen drawn with colours can be looked at in a browser (used by tests/tools/gallery.sh).
usage: ansi2html.py INPUT.ansi OUTPUT.html [title]      (several INPUTs: ansi2html.py -o OUTPUT.html title IN1 IN2 ...)"""
import html, re, sys

BASE16 = ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
          "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff"]


def x256(n):
    if n < 16:
        return BASE16[n]
    if n >= 232:
        v = 8 + (n - 232) * 10
        return "#%02x%02x%02x" % (v, v, v)
    n -= 16
    lv = [0, 95, 135, 175, 215, 255]
    return "#%02x%02x%02x" % (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])


def convert(text):
    out, fg, bg, bold, dim, rev = [], None, None, False, False, False
    pos = 0

    def span(chunk):
        if not chunk:
            return
        f, b = (bg, fg) if rev else (fg, bg)
        if rev:
            f = f or "#0b0f0c"
            b = b or "#d8d8d8"
        st = []
        if f:
            st.append("color:" + f)
        if b:
            st.append("background:" + b)
        if bold:
            st.append("font-weight:bold")
        if dim:
            st.append("opacity:.6")
        out.append('<span style="%s">%s</span>' % (";".join(st), html.escape(chunk)) if st else html.escape(chunk))

    for m in re.finditer(r"\x1b\[([0-9;]*)m", text):
        span(text[pos:m.start()])
        pos = m.end()
        ps = [int(x) if x else 0 for x in m.group(1).split(";")] if m.group(1) else [0]
        i = 0
        while i < len(ps):
            p = ps[i]
            if p == 0:
                fg = bg = None; bold = dim = rev = False
            elif p == 1: bold = True
            elif p == 2: dim = True
            elif p == 7: rev = True
            elif p == 22: bold = dim = False
            elif p == 27: rev = False
            elif 30 <= p <= 37: fg = BASE16[p - 30]
            elif 90 <= p <= 97: fg = BASE16[p - 90 + 8]
            elif 40 <= p <= 47: bg = BASE16[p - 40]
            elif 100 <= p <= 107: bg = BASE16[p - 100 + 8]
            elif p == 39: fg = None
            elif p == 49: bg = None
            elif p in (38, 48) and i + 1 < len(ps):
                if ps[i + 1] == 2 and i + 4 < len(ps):
                    col = "#%02x%02x%02x" % tuple(ps[i + 2:i + 5]); i += 4
                elif ps[i + 1] == 5 and i + 2 < len(ps):
                    col = x256(ps[i + 2]); i += 2
                else:
                    col = None
                if p == 38: fg = col
                else: bg = col
            i += 1
    span(text[pos:])
    return "".join(out)


def page(title, parts):
    body = "\n".join("<h3>%s</h3><pre>%s</pre>" % (html.escape(name), convert(txt)) for name, txt in parts)
    return ("<!doctype html><meta charset=utf-8><title>%s</title><style>body{background:#101412;color:#c8c8c8;font:14px/1.15 'DejaVu Sans Mono',monospace;margin:16px}"
            "h3{color:#7fbf8f;font-weight:normal;margin:20px 0 4px}pre{background:#050a06;padding:8px;margin:0;overflow:auto;line-height:1.15}</style>%s" % (html.escape(title), body))


if __name__ == "__main__":
    if sys.argv[1] == "-o":
        out, title, ins = sys.argv[2], sys.argv[3], sys.argv[4:]
        open(out, "w").write(page(title, [(i, open(i).read()) for i in ins]))
    else:
        inp, out = sys.argv[1], sys.argv[2]
        open(out, "w").write(page(sys.argv[3] if len(sys.argv) > 3 else inp, [(inp, open(inp).read())]))
