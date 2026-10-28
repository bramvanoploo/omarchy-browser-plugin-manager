#!/usr/bin/env python3
"""Crop the wizard dialog card out of a full-screen grim capture.

The wizard overlay centers an accent-bordered card on a dark scrim. Sample the
theme accent from the most saturated pixel on the screen midlines, then walk
outward from the screen center along the midlines; an edge is the first accent
pixel that continues as a long accent run along the perpendicular direction
(short accent runs are the accent-colored text lines inside the card). Crop
the resulting rectangle with a small margin.

Usage: crop-wizard.py <full-capture.png> <out.png>
"""
import sys
from PIL import Image


def close(c, r, tol=120):
    return abs(c[0] - r[0]) + abs(c[1] - r[1]) + abs(c[2] - r[2]) < tol


def run_len(px, get, start, step, n, ref, tol=120):
    count = 0
    i = start
    while 0 <= i < n and close(get(i), ref, tol):
        count += 1
        i += step
    return count


def main():
    src, dst = sys.argv[1], sys.argv[2]
    im = Image.open(src).convert("RGB")
    w, h = im.size
    px = im.load()
    cx, cy = w // 2, h // 2

    samples = [px[x, cy] for x in range(int(cx * 0.35), w, 3)]
    samples += [px[cx, y] for y in range(int(cy * 0.35), h, 3)]
    ref = max(samples, key=lambda c: (max(c) - min(c)) + max(c) // 3)
    if max(ref) - min(ref) < 40:
        raise SystemExit("no saturated accent border found on midlines")

    need = max(w, h) // 12

    def edge(axis, sign):
        pos = cx if axis == "x" else cy
        n = w if axis == "x" else h
        while True:
            pos += sign
            if pos < 2 or pos > n - 3:
                return pos
            if axis == "x":
                if not close(px[pos, cy], ref):
                    continue
                up = run_len(px, lambda t: px[pos, t], cy, -1, h, ref)
                down = run_len(px, lambda t: px[pos, t], cy, 1, h, ref)
            else:
                if not close(px[cx, pos], ref):
                    continue
                up = run_len(px, lambda t: px[t, pos], cx, -1, w, ref)
                down = run_len(px, lambda t: px[t, pos], cx, 1, w, ref)
            if up + down >= need:
                return pos

    m = 12
    left = edge("x", -1) - m
    right = edge("x", 1) + m + 1
    top = edge("y", -1) - m
    bottom = edge("y", 1) + m + 1
    box = (max(0, left), max(0, top), min(w, right), min(h, bottom))
    im.crop(box).save(dst)
    print(f"{dst}: {box[2]-box[0]}x{box[3]-box[1]}")


if __name__ == "__main__":
    main()
