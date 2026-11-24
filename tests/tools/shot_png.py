#!/usr/bin/env python3
"""Draws the JSON written by pty_shot.py as a PNG with Pillow (the same picture tests/tools/render_shot.ps1 draws with System.Drawing, for
machines without PowerShell). A monospace font with the braille block is needed: DejaVu Sans Mono, JetBrains Mono, Noto Sans Mono...

usage: shot_png.py shot.json shot.png [cell_width cell_height font_size]      (defaults 9 18 14)
       shot_png.py frame.ansi shot.png [cell_width cell_height font_size]     a frame as the panel prints it in test mode with colours
                                                                              (DELTACTL_COLOR=always COLORTERM=truecolor), one line per row
       DELTACTL_FONT=/path/to/font.ttf  DELTACTL_FONT_BOLD=/path/to/bold.ttf  DELTACTL_FONT_BRAILLE=/path/to/font.ttf   choose the fonts"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont

CANDIDATES = [
    ("/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf"),
    ("/usr/share/fonts/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/dejavu/DejaVuSansMono-Bold.ttf"),
    ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"),
    ("/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf", "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Bold.ttf"),
    ("/usr/share/fonts/noto/NotoSansMono-Regular.ttf", "/usr/share/fonts/noto/NotoSansMono-Bold.ttf"),
]


def pick_fonts(size):
    reg, bold = os.environ.get("DELTACTL_FONT"), os.environ.get("DELTACTL_FONT_BOLD")
    if reg:
        return ImageFont.truetype(reg, size), ImageFont.truetype(bold or reg, size)
    for r, b in CANDIDATES:
        if os.path.exists(r):
            return ImageFont.truetype(r, size), ImageFont.truetype(b if os.path.exists(b) else r, size)
    sys.exit("shot_png.py: no monospace font found (set DELTACTL_FONT)")


BRAILLE = ["/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
           "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf"]


def braille_font(size):
    """DejaVu Sans Mono has no braille block; the proportional one does. Each glyph is centred in its cell."""
    for f in [os.environ.get("DELTACTL_FONT_BRAILLE")] + BRAILLE:
        if f and os.path.exists(f):
            return ImageFont.truetype(f, size)
    return None


def ansi_to_shot(path):
    """Feeds the lines of a frame through the terminal emulator of pty_shot.py and returns the same dictionary it saves."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import pty_shot, re
    lines = [l for l in open(path, encoding="utf-8").read().split("\n")]
    while lines and not lines[-1]:
        lines.pop()
    vis = lambda l: len(re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", l))
    cols = max(vis(l) for l in lines)
    screen = pty_shot.Screen(len(lines), cols)
    for l in lines:
        screen.feed((l + "\x1b[0m\r\n").encode("utf-8"))
    return {"rows": len(lines), "cols": cols, "cells": screen.dump()}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    cw = int(sys.argv[3]) if len(sys.argv) > 3 else 9
    ch = int(sys.argv[4]) if len(sys.argv) > 4 else 18
    size = int(sys.argv[5]) if len(sys.argv) > 5 else 14
    if src.endswith(".ansi"):
        data = ansi_to_shot(src)
    else:
        data = json.load(open(src, encoding="utf-8"))
    rows, cols = data["rows"], data["cols"]
    def_fg, def_bg = (204, 204, 204), (24, 26, 32)
    font_r, font_b = pick_fonts(size)
    font_br = braille_font(size)
    img = Image.new("RGB", (cols * cw, rows * ch), def_bg)
    d = ImageDraw.Draw(img)

    def colors(cell):
        fg = tuple(cell[1]) if cell[1] else def_fg
        bg = tuple(cell[2]) if cell[2] else def_bg
        fl = int(cell[3])
        if fl & 4:
            fg, bg = bg, fg
        if fl & 2:
            fg = tuple((a + b) // 2 for a, b in zip(fg, bg))
        return fg, bg, fl

    for y in range(rows):
        row = data["cells"][y]
        for x in range(cols):
            fg, bg, fl = colors(row[x])
            if bg != def_bg:
                d.rectangle([x * cw, y * ch, (x + 1) * cw - 1, (y + 1) * ch - 1], fill=bg)
        for x in range(cols):
            c = row[x][0]
            if c == " ":
                continue
            fg, bg, fl = colors(row[x])
            if font_br is not None and "\u2800" <= c <= "\u28ff":
                w = d.textlength(c, font=font_br)
                d.text((x * cw + (cw - w) / 2, y * ch + 1), c, font=font_br, fill=fg)
                continue
            d.text((x * cw, y * ch + 1), c, font=font_b if fl & 1 else font_r, fill=fg)
    img.save(dst)
    print("saved %s (%dx%d)" % (dst, cols * cw, rows * ch))


main()
