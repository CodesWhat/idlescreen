"""Tiny RGBA pixel canvas and PNG writer, stdlib only."""
import struct
import zlib


def rgba(c):
    if isinstance(c, tuple):
        return c if len(c) == 4 else c + (255,)
    c = c.lstrip("#")
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def mix(a, b, t):
    a, b = rgba(a), rgba(b)
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(4))


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.p = [[(0, 0, 0, 0)] * w for _ in range(h)]

    def px(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.p[y][x] = rgba(c)

    def scaled(self, s):
        """Nearest neighbour, integer factor."""
        o = Canvas(self.w * s, self.h * s)
        for y, row in enumerate(self.p):
            wide = [px for px in row for _ in range(s)]
            for j in range(s):
                o.p[y * s + j] = list(wide)
        return o

    def boxed(self, s):
        """Box filter down by an integer factor, alpha-weighted."""
        o = Canvas(self.w // s, self.h // s)
        n = s * s
        for y in range(o.h):
            for x in range(o.w):
                acc = [0, 0, 0, 0]
                for j in range(s):
                    for i in range(s):
                        r, g, b, a = self.p[y * s + j][x * s + i]
                        acc[0] += r * a
                        acc[1] += g * a
                        acc[2] += b * a
                        acc[3] += a
                if acc[3] == 0:
                    continue
                o.p[y][x] = tuple(int(round(acc[i] / acc[3])) for i in range(3)) + (int(round(acc[3] / n)),)
        return o

    def png(self, path):
        raw = bytearray()
        for row in self.p:
            raw += b"\x00" + b"".join(bytes(px) for px in row)

        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
        out += chunk(b"sRGB", b"\x00") + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
        open(path, "wb").write(out)
