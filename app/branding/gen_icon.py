#!/usr/bin/env python3
"""Ply app icon — a 2-ply twisted-cord roundel (the literal meaning of 'ply') in madder on cream.
Generates three SVG masters; render_icons.sh rasterizes them into the Android/iOS launcher sets.

  composed.svg    full-bleed cream square + roundel  -> iOS, legacy Android ic_launcher
  foreground.svg  roundel only, transparent, sized for the adaptive safe zone -> adaptive foreground
  preview.svg     rounded-square (squircle) preview
"""
import math, os

S = 512
BG = "#F3EEE3"                 # warm cream
FRONT = (0xD0, 0x72, 0x4E)    # madder, lit strand
BACK = (0x6E, 0x2E, 0x1E)     # madder, shadowed strand
OUT = os.path.dirname(os.path.abspath(__file__))

def shade(z):
    t = (z + 1) / 2
    return "#%02x%02x%02x" % tuple(round(BACK[i] + (FRONT[i] - BACK[i]) * t) for i in range(3))

def roundel_segs(R, amp, turns, w, n=2):
    cx = cy = S / 2
    steps = 480
    segs = []
    for i in range(steps):
        t0 = 2 * math.pi * i / steps
        t1 = 2 * math.pi * (i + 1) / steps
        for k in range(n):
            off = 2 * math.pi * k / n
            f0, f1 = turns * t0 + off, turns * t1 + off
            r0, r1 = R + amp * math.cos(f0), R + amp * math.cos(f1)
            x0, y0 = cx + r0 * math.cos(t0), cy + r0 * math.sin(t0)
            x1, y1 = cx + r1 * math.cos(t1), cy + r1 * math.sin(t1)
            z = (math.sin(f0) + math.sin(f1)) / 2
            segs.append((z, x0, y0, x1, y1, w))
    return sorted(segs, key=lambda s: s[0])

def body(segs):
    return "".join(
        f'<path d="M {x1:.1f} {y1:.1f} L {x2:.1f} {y2:.1f}" stroke="{shade(z)}" '
        f'stroke-width="{w}" stroke-linecap="round" fill="none"/>'
        for (z, x1, y1, x2, y2, w) in segs
    )

def write(name, prelude, segs):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
           f'viewBox="0 0 {S} {S}">{prelude}{body(segs)}</svg>')
    open(os.path.join(OUT, name), "w").write(svg)

# Composed (iOS + legacy Android): roundel at ~73% on a full-bleed cream square; the OS masks corners.
write("composed.svg", f'<rect width="{S}" height="{S}" fill="{BG}"/>',
      roundel_segs(R=128, amp=40, turns=7, w=40))
# Squircle preview.
write("preview.svg", f'<rect width="{S}" height="{S}" rx="112" fill="{BG}"/>',
      roundel_segs(R=128, amp=40, turns=7, w=40))
# Adaptive foreground: roundel only (transparent), scaled into the central ~59% safe zone.
write("foreground.svg", "", roundel_segs(R=104, amp=33, turns=7, w=30))
print("wrote composed.svg, preview.svg, foreground.svg")
