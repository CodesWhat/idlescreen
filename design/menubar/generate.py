"""IdleScreen menu bar glyphs, the CRT object. Standard library only.

Run from anywhere: python3 -I design/menubar/generate.py

Writes the template glyph imagesets into the app's asset catalog and a preview
sheet next to this file. Output is deterministic and checked in, so builds never
need Python.

1x grid is 16x15; the CRT is 14 wide x 13 tall at offset (1,1).
2x is hand-drawn on a 32x30 grid (rounded bezel, highlight notch, true ellipse eye), not pixel-doubled.
"""
import json, os, struct, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CATALOG = os.path.join(REPO, "Products", "IdleScreenApp", "Assets.xcassets")
W, H = 16, 15

# 14x13 chassis, '#' = ink. Tube rows 0..10, neck row 11, foot row 12.
CHASSIS = [
    "." + "#" * 12 + ".",
    "##############",
    "##..........##",
    "#............#",
    "#............#",
    "#............#",
    "#............#",
    "#............#",
    "##..........##",
    "##############",
    "." + "#" * 12 + ".",
    "....######....",
    "..##########..",
]

# content window: 10 wide x 5 tall at chassis (2,3), one blank ring inside the bezel
CX, CY = 2, 3
def RAIN(frame):
    """three solid 2px streaks of different length; each falls 1 row (wrapping) between frames"""
    rows = [["."] * 10 for _ in range(5)]
    for x0, start, n in ((1, 0, 4), (4, 2, 3), (7, 0, 3)):
        for k in range(n):
            y = (start + frame + k) % 5
            rows[y][x0] = rows[y][x0 + 1] = "#"
    return ["".join(r) for r in rows]


SCREENS = {
    # ready: three heavy scanlines at 2px pitch
    "idle": ["##########", "..........", "##########", "..........", "##########"],
    # saver running: two solid 2px columns that shift 2 rows. running0 is the Reduce Motion still
    "running0": RAIN(0),
    "running1": RAIN(1),
    # camera: eye-dot, glances 2px. camera0 is the Reduce Motion still
    "camera0": ["..######..", "..######..", "..######..", "..######..", "..######.."],
    "camera1": ["....######", "....######", "....######", "....######", "....######"],
    # agent signal: a bang
    "attention": ["...####...", "...####...", "...####...", "..........", "...####..."],
    "setup": [".........."] * 5,
}
ORDER = ["idle", "running0", "running1", "camera0", "camera1", "attention", "setup"]
MEANING = {
    "idle": "ready, nothing running", "running0": "saver running / previewing (still)",
    "running1": "saver running frame 2", "camera0": "camera watching (still)",
    "camera1": "camera watching frame 2", "attention": "agent signal needs attention",
    "setup": "needs setup / unavailable",
}


def blank(w, h):
    return [[0] * w for _ in range(h)]


def build_1x(name):
    g = blank(W, H)
    for y, row in enumerate(CHASSIS):
        for x, c in enumerate(row):
            g[1 + y][1 + x] = 1 if c == "#" else 0
    scr = SCREENS[name]
    if name.startswith("camera"):
        # round the eye: knock the four corners of the 6x5 block
        scr = [list(r) for r in scr]
        xs = [i for i, c in enumerate(scr[0]) if c == "#"]
        for r in (0, 4):
            scr[r][xs[0]] = "."
            scr[r][xs[-1]] = "."
        scr = ["".join(r) for r in scr]
    if name == "running0" or name == "running1":
        pass
    for y, row in enumerate(scr):
        for x, c in enumerate(row):
            g[1 + CY + y][1 + CX + x] = 1 if c == "#" else 0
    if name == "setup":
        slash(g, [(2 + i, 13 - i) for i in range(12)], 2, 1)
    return g


def slash(g, pts, thick, gap):
    """2px-thick slash with a clear `gap` px either side so it survives the bezel."""
    h, w = len(g), len(g[0])
    ink = set()
    for x, y in pts:
        for t in range(thick):
            ink.add((x + t, y))
    for x, y in ink:
        for dy in range(-gap, gap + 1):
            for dx in range(-gap, gap + 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in ink:
                    g[ny][nx] = 0
    for x, y in ink:
        g[y][x] = 1


# ---------- hand-drawn 2x ----------
def rrect(g, x0, y0, x1, y1, r, v=1):
    """filled rounded rect, inclusive bounds, corner radius r (pixel-center test)."""
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            cx = x0 + r if x < x0 + r else (x1 - r if x > x1 - r else None)
            cy = y0 + r if y < y0 + r else (y1 - r if y > y1 - r else None)
            if cx is not None and cy is not None:
                if (x - cx) ** 2 + (y - cy) ** 2 > (r - 0.35) ** 2 + 0.5:
                    continue
            g[y][x] = v


def ellipse(g, cx, cy, rx, ry, v=1):
    for y in range(len(g)):
        for x in range(len(g[0])):
            if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1.0:
                g[y][x] = v


def build_2x(name):
    g = blank(32, 30)
    ox, oy = 2, 2  # glyph origin
    # tube: 28 x 22, bezel 3px, rounded 5 outside, 3 inside
    rrect(g, ox, oy, ox + 27, oy + 21, 5, 1)
    rrect(g, ox + 3, oy + 3, ox + 24, oy + 18, 3, 0)
    # bezel highlight: clear the middle bezel ring along the top-left
    for x in range(ox + 7, ox + 15):
        g[oy + 1][x] = 0
    for y in range(oy + 7, oy + 12):
        g[y][ox + 1] = 0
    # neck and foot (2 rows each, foot corners rounded)
    for y in range(oy + 22, oy + 24):
        for x in range(ox + 8, ox + 20):
            g[y][x] = 1
    rrect(g, ox + 4, oy + 24, ox + 23, oy + 25, 1, 1)
    # screen content: window 20x10 at glyph (4,6)
    sx, sy = ox + 4, oy + 6
    scr = SCREENS[name]
    if name.startswith("camera"):
        x0 = sx + (4 if name == "camera0" else 8)
        ellipse(g, x0 + 6, sy + 5, 6.2, 5.2, 1)
    elif name.startswith("running"):
        for y, row in enumerate(scr):
            for x, c in enumerate(row):
                if c == "#":
                    for j in range(2):
                        for i in range(2):
                            g[sy + y * 2 + j][sx + x * 2 + i] = 1
        # soften the head of each column (bottom corners of the lowest cell)
        for xx in range(20):
            col = [g[sy + yy][sx + xx] for yy in range(10)]
        for cxs in (sx + 2, sx + 14):
            pass
    elif name == "attention":
        # tapered stem and round dot
        for y in range(0, 6):
            half = 4 if y < 4 else 3
            for x in range(10 - half, 10 + half):
                g[sy + y][sx + x] = 1
        ellipse(g, sx + 10, sy + 8.8, 3.2, 1.3, 1)
    elif name != "setup":
        for y, row in enumerate(scr):
            for x, c in enumerate(row):
                if c == "#":
                    for j in range(2):
                        for i in range(2):
                            g[sy + y * 2 + j][sx + x * 2 + i] = 1
    if name == "setup":
        slash(g, [(4 + i, 26 - i) for i in range(23)], 4, 2)
    return g


def to_png(path, g, scale=1):
    h, w = len(g), len(g[0])
    raw = bytearray()
    for y in range(h * scale):
        raw += b"\x00"
        for x in range(w * scale):
            raw += bytes((0, 0, 0, 255 if g[y // scale][x // scale] else 0))
    write_png(path, w * scale, h * scale, raw)


def write_png(path, w, h, raw):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# ---------- sheet rendering ----------
LIGHT, DARK = (236, 236, 236), (30, 30, 30)
FONT = {
    "a": "010101111101101", "b": "110101110101110", "c": "011100100100011", "d": "110101101101110",
    "e": "111100110100111", "f": "111100110100100", "g": "011100101101011", "h": "101101111101101",
    "i": "111010010010111", "j": "001001001101010", "k": "101101110101101", "l": "100100100100111",
    "m": "101111111101101", "n": "110101101101101", "o": "010101101101010", "p": "110101110100100",
    "q": "010101101111011", "r": "110101110101101", "s": "011100010001110", "t": "111010010010010",
    "u": "101101101101111", "v": "101101101101010", "w": "101101111111101", "x": "101101010101101",
    "y": "101101010010010", "z": "111001010100111", " ": "0" * 15, "1": "010110010010111", "4": "101101111001001", "0": "111101101101111",
    "2": "110001010100111", "x2": "", "8": "111101111101111", "/": "001001010100100",
    "(": "010100100100010", ")": "010001001001010", ",": "000000000010100", "-": "000000111000000",
}


class Canvas:
    def __init__(self, w, h, bg):
        self.w, self.h = w, h
        self.px = [[bg] * w for _ in range(h)]

    def rect(self, x, y, w, h, c):
        for yy in range(max(0, y), min(self.h, y + h)):
            for xx in range(max(0, x), min(self.w, x + w)):
                self.px[yy][xx] = c

    def grid(self, g, x, y, s, c):
        for j, row in enumerate(g):
            for i, v in enumerate(row):
                if v:
                    self.rect(x + i * s, y + j * s, s, s, c)

    def text(self, s, x, y, c, sc=1):
        for ch in s.lower():
            f = FONT.get(ch, FONT[" "])
            for k, b in enumerate(f):
                if b == "1":
                    self.rect(x + (k % 3) * sc, y + (k // 3) * sc, sc, sc, c)
            x += 4 * sc

    def save(self, name):
        raw = bytearray()
        for row in self.px:
            raw += b"\x00" + b"".join(bytes(p + (255,)) for p in row)
        write_png(os.path.join(HERE, name), self.w, self.h, raw)


def fg_for(bg):
    return (255, 255, 255) if bg == DARK else (0, 0, 0)


def imageset_name(name):
    return "MenuBarCRT" + name[0].upper() + name[1:]


def write_imageset(name, g1, g2):
    d = os.path.join(CATALOG, imageset_name(name) + ".imageset")
    os.makedirs(d, exist_ok=True)
    to_png(os.path.join(d, f"crt-{name}.png"), g1, 1)
    to_png(os.path.join(d, f"crt-{name}@2x.png"), g2, 1)
    contents = {
        "images": [
            {"idiom": "universal", "filename": f"crt-{name}.png", "scale": "1x"},
            {"idiom": "universal", "filename": f"crt-{name}@2x.png", "scale": "2x"},
        ],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    }
    with open(os.path.join(d, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2, sort_keys=True)
        f.write("\n")


def preview_sheet(grids, grids2x):
    """Light and dark strips: each state at 1x, at 8x, and the hand-drawn 2x at 4x."""
    S = 8
    pad = 16
    cell = 32 * 4 + 16
    inner_w = len(ORDER) * cell
    row_h = 14 + 15 * S + 8 + 30 * 4 + 16
    cv = Canvas(inner_w + pad * 2, 2 * (row_h + 8) + pad * 2, (246, 246, 246))
    y = pad
    for bg in (LIGHT, DARK):
        fg = fg_for(bg)
        cv.rect(pad, y, inner_w, row_h, bg)
        for k, name in enumerate(ORDER):
            x0 = pad + k * cell + 8
            cv.text(name, x0, y + 4, fg, 1)
            cv.grid(grids[k], x0 + 100, y + 2, 1, fg)
            cv.grid(grids[k], x0, y + 14, S, fg)
            cv.grid(grids2x[k], x0, y + 14 + 15 * S + 8, 4, fg)
        y += row_h + 8
    cv.save("preview.png")


def main():
    g1, g2 = [], []
    for name in ORDER:
        a, b = build_1x(name), build_2x(name)
        g1.append(a)
        g2.append(b)
        write_imageset(name, a, b)
    preview_sheet(g1, g2)
    for n, g in zip(ORDER, g1):
        print(n)
        print("\n".join("".join("#" if v else "." for v in r) for r in g))
    print("ok")


main()
