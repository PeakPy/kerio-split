#!/usr/bin/env python3
"""Make Kerio Split app icon corners transparent without corrupting pixels.

Properly decodes PNG scanline filters (sips output is often filtered).
"""
from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png(path: Path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8
    w = h = color = None
    idat = b""
    while pos < len(data):
        ln = struct.unpack(">I", data[pos : pos + 4])[0]
        typ = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            w, h, bit, color = struct.unpack(">IIBB", chunk[:10])
            if bit != 8:
                raise SystemExit(f"unsupported bit depth {bit}")
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
    raw = bytearray(zlib.decompress(idat))
    bpp = {2: 3, 6: 4}[color]
    stride = w * bpp
    rows = []
    prev = bytearray(stride)
    i = 0
    for _y in range(h):
        ftype = raw[i]
        i += 1
        row = bytearray(raw[i : i + stride])
        i += stride
        if ftype == 1:  # Sub
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + left) & 255
        elif ftype == 2:  # Up
            for x in range(stride):
                row[x] = (row[x] + prev[x]) & 255
        elif ftype == 3:  # Average
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + ((left + prev[x]) // 2)) & 255
        elif ftype == 4:  # Paeth
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                up = prev[x]
                up_left = prev[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + paeth(left, up, up_left)) & 255
        elif ftype != 0:
            raise SystemExit(f"unsupported filter {ftype}")
        prev = row
        line = []
        for x in range(w):
            o = x * bpp
            if bpp == 3:
                line.append([row[o], row[o + 1], row[o + 2], 255])
            else:
                line.append([row[o], row[o + 1], row[o + 2], row[o + 3]])
        rows.append(line)
    return w, h, rows


def write_png_rgba(path: Path, pixels):
    h = len(pixels)
    w = len(pixels[0])
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter None
        for r, g, b, a in pixels[y]:
            raw.extend((r, g, b, a))
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", compressed)
        + chunk(b"IEND", b"")
    )


def inside_rounded_rect(x: float, y: float, w: float, h: float, radius: float) -> bool:
    radius = min(radius, w / 2, h / 2)
    if radius <= x <= w - radius and 0 <= y <= h:
        return True
    if radius <= y <= h - radius and 0 <= x <= w:
        return True
    if x < radius and y < radius:
        return (x - radius) ** 2 + (y - radius) ** 2 <= radius ** 2
    if x > w - radius and y < radius:
        return (x - (w - radius)) ** 2 + (y - radius) ** 2 <= radius ** 2
    if x < radius and y > h - radius:
        return (x - radius) ** 2 + (y - (h - radius)) ** 2 <= radius ** 2
    if x > w - radius and y > h - radius:
        return (x - (w - radius)) ** 2 + (y - (h - radius)) ** 2 <= radius ** 2
    return 0 <= x <= w and 0 <= y <= h


def clean(path_in: Path, path_out: Path):
    w, h, pixels = read_png(path_in)
    # sanity: center should not be near-white for logo C
    cr, cg, cb, _ = pixels[h // 2][w // 2]
    print(f"centerRGB=({cr},{cg},{cb}) cornerRGB={tuple(pixels[0][0][:3])}")

    radius = min(w, h) * 0.2237
    inset = 2.0
    opaque = 0
    out = []
    for y in range(h):
        row = []
        for x in range(w):
            r, g, b, a = pixels[y][x]
            ix = x + 0.5 - inset
            iy = y + 0.5 - inset
            iw = w - 2 * inset
            ih = h - 2 * inset
            if ix < 0 or iy < 0 or ix > iw or iy > ih or not inside_rounded_rect(
                ix, iy, iw, ih, max(1.0, radius - inset)
            ):
                row.append([0, 0, 0, 0])
                continue
            luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            sat = (max(r, g, b) - min(r, g, b)) / 255.0
            if luma > 0.90 and sat < 0.10:
                row.append([0, 0, 0, 0])
                continue
            row.append([r, g, b, 255])
            opaque += 1
        out.append(row)
    write_png_rgba(path_out, out)
    print(f"cleaned {path_out.name} opaque={opaque}/{w*h} cornerRGBA={out[0][0]}")


if __name__ == "__main__":
    clean(Path(sys.argv[1]), Path(sys.argv[2]) if len(sys.argv) > 2 else Path(sys.argv[1]))
