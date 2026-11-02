"""The idlescreen CRT as role grids. Python 3 stdlib only.

Roles: . background, o outline, b body, s screen, g phosphor glow, d stand, l power LED.
`grid32` is the master drawing (a 32 cell grid, 32 px per cell on the 1024 master); `grid16` is the hand drawn
16 px version."""
import math

PALETTE = {".": "#3B6CF0", "o": "#1B1B1F", "b": "#F6F0DC", "s": "#1B1B1F", "g": "#3DFF7A", "d": "#1B1B1F", "l": "#3DFF7A"}
BAYER4 = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


class Grid:
    def __init__(self, n):
        self.n = n
        self.c = [["."] * n for _ in range(n)]

    def set(self, x, y, r):
        if 0 <= x < self.n and 0 <= y < self.n:
            self.c[y][x] = r

    def rect(self, x0, y0, x1, y1, r, cut=0):
        """Fill a rectangle; cut trims the corners diagonally."""
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if min(x - x0, x1 - x) + min(y - y0, y1 - y) >= cut:
                    self.set(x, y, r)

    def shell(self, x0, y0, x1, y1, cut):
        self.rect(x0, y0, x1, y1, "o", cut)
        self.rect(x0 + 1, y0 + 1, x1 - 1, y1 - 1, "b", max(cut - 1, 0))


def glow(g, x0, y0, x1, y1, fall):
    """Phosphor glow: a Bayer dithered ellipse, dense at the centre of the screen."""
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    rx, ry = (x1 - x0 + 1) / 2, (y1 - y0 + 1) / 2
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            val = 1.15 - math.hypot((x - cx) / rx, (y - cy) / ry) * fall
            if val > (BAYER4[y % 4][x % 4] + 0.5) / 16:
                g.set(x, y, "g")


def grid32():
    g = Grid(32)
    g.shell(3, 3, 28, 25, 2)
    g.rect(6, 6, 25, 20, "s", 2)
    glow(g, 7, 7, 24, 19, 0.95)
    g.rect(23, 22, 24, 23, "l")
    g.rect(13, 25, 18, 27, "d")
    g.rect(8, 28, 23, 29, "d", 1)
    return g


GLOW16 = [  # screen interior x4..11, y5..8
    "g.gggg.g",
    ".gggggg.",
    ".gggggg.",
    "g.gggg.g",
]


def grid16():
    g = Grid(16)
    g.shell(1, 2, 14, 11, 1)
    g.rect(3, 4, 12, 9, "s")
    for j, row in enumerate(GLOW16):
        for i, ch in enumerate(row):
            if ch == "g":
                g.set(4 + i, 5 + j, "g")
    g.rect(6, 11, 9, 12, "d")
    g.rect(3, 13, 12, 14, "d")
    return g
