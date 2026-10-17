#!/usr/bin/env python3
"""The Trails mark: the S drawn by star trails, the arcs stars leave across a
long exposure. Each lane is one star's trail; the lanes start and stop at
different points because each star was in frame for a different stretch.

Geometry, lanes, levels and palettes are a straight port of the approved
reference (brand-ref/trails_reference.py). Everything downstream of this file
is generated; nothing edits the mark by hand.
"""

import argparse
import math

R0 = 14.0          # centerline radius of each bowl
CY_UP, CY_LO = 36.0, 64.0
CX = 50.0

# The tile an app icon sits on: ground color and corner radius (22.5% of side).
# The red night-mode colorway is the exception: it sits on pure black.
GROUND = "#0E0C16"
TILE_RX = 22.5

# Apple's icon grid: an 824 px rounded body centered on the 1024 canvas.
MACOS_BODY = 824.0 / 1024.0

# Android adaptive icons: the mark lives inside the 66 dp safe zone of the
# 108 dp canvas, so the 100-unit frame draws at 66 units. Web maskable icons
# use the 80% safe circle instead.
ADAPTIVE_SAFE = 0.66
MASKABLE_SAFE = 0.80


def pt(cx, cy, r, t):
    a = math.radians(t)
    return cx + r * math.cos(a), cy + r * math.sin(a)


def lane(offset, up_start, lo_end):
    ru, rl = R0 + offset, R0 - offset
    x0, y0 = pt(CX, CY_UP, ru, up_start)
    xm, ym = pt(CX, CY_UP, ru, 90)          # the S's waist, shared by both arcs
    x1, y1 = pt(CX, CY_LO, rl, lo_end)
    # Upper arc runs counterclockwise (decreasing angle) from up_start to 90-360.
    sweep_up = (up_start - (90 - 360)) % 360
    large_up = 1 if sweep_up > 180 else 0
    sweep_lo = (lo_end - (-90)) % 360
    large_lo = 1 if sweep_lo > 180 else 0
    return (f"M{x0:.2f},{y0:.2f} A{ru:.2f},{ru:.2f} 0 {large_up} 0 {xm:.2f},{ym:.2f} "
            f"A{rl:.2f},{rl:.2f} 0 {large_lo} 1 {x1:.2f},{y1:.2f}")


def lane_mapped(offset, up_start, lo_end, k, tx, ty):
    """The same path as lane() with a uniform scale + translate applied.

    Only endpoints and radii change: a circular arc under uniform scale stays
    circular, so the flags carry over untouched."""
    ru, rl = (R0 + offset) * k, (R0 - offset) * k
    x0, y0 = (v * k + t for v, t in zip(pt(CX, CY_UP, R0 + offset, up_start), (tx, ty)))
    xm, ym = (v * k + t for v, t in zip(pt(CX, CY_UP, R0 + offset, 90), (tx, ty)))
    x1, y1 = (v * k + t for v, t in zip(pt(CX, CY_LO, R0 - offset, lo_end), (tx, ty)))
    sweep_up = (up_start - (90 - 360)) % 360
    large_up = 1 if sweep_up > 180 else 0
    sweep_lo = (lo_end - (-90)) % 360
    large_lo = 1 if sweep_lo > 180 else 0
    return (f"M{x0:.2f},{y0:.2f} A{ru:.2f},{ru:.2f} 0 {large_up} 0 {xm:.2f},{ym:.2f} "
            f"A{rl:.2f},{rl:.2f} 0 {large_lo} 1 {x1:.2f},{y1:.2f}")


PALETTES = {
    "violet": ["#6E56CF", "#8F7BEA", "#B9ABFF", "#E4DEFF", "#FFD9A8"],
    "night": ["#5B6CF0", "#8A93FF", "#C7C9FF", "#F2F0FF", "#FFC98B"],
    "mono": ["#EDEAF7"] * 5,
    "light": ["#4B36A8", "#6A55CC", "#8E7BE3", "#2B2347", "#E08A3C"],
    "red": ["#7A1C14", "#A3271C", "#CC3426", "#F04A38", "#FF7A66"],
}

# Lanes, outer (top bowl) to inner: offset, where the trail starts in the top
# bowl (degrees, y down), where it ends in the bottom bowl.
LANES = [(8.4, -38, 132), (4.2, -22, 150), (0.0, -46, 140), (-4.2, -30, 160), (-8.4, -60, 118)]


# Fewer, heavier trails as the mark gets small, so the lanes never merge.
LEVELS = {
    "full": (LANES, 3.0, [0, 1, 2, 3, 4], 2.2),
    "mid": ([(7.0, -38, 132), (0.0, -46, 140), (-7.0, -60, 118)], 4.6, [0, 2, 4], 3.0),
    "flat": ([(4.6, -40, 134), (-4.6, -52, 124)], 6.4, [1, 4], 0),
}

# The layout transform every form of the mark shares.
MARK_TRANSFORM = "translate(50 50) scale(1.08) translate(-50 -50.5)"


def level_for_size(px):
    """Pixel size of the rendered mark -> level of detail."""
    if px < 24:
        return "flat"
    if px < 64:
        return "mid"
    return "full"


def lane_colors(palette, level):
    """The stroke color of each lane drawn at a level, outermost first."""
    cols, pick = PALETTES[palette], LEVELS[level][2]
    return [cols[k] for k in pick]


def pole_color(palette):
    return PALETTES[palette][3]


def elements(palette="violet", level="full"):
    """The mark's elements (lanes + pole star) inside the layout transform."""
    lanes, width, _, dot = LEVELS[level]
    p = [f'<g transform="{MARK_TRANSFORM}">']
    for (o, s, e), c in zip(lanes, lane_colors(palette, level)):
        p.append(f'<path d="{lane(o, s, e)}" fill="none" stroke="{c}" '
                 f'stroke-width="{width}" stroke-linecap="round"/>')
    if dot:
        p.append(f'<circle cx="{CX}" cy="{CY_UP}" r="{dot}" fill="{pole_color(palette)}"/>')
    return p


def group(palette="violet", level="full"):
    """The mark as a reusable <g> block in the 100x100 frame."""
    return "\n".join(elements(palette, level) + ["</g>"])


def svg(palette="violet", size=512, tile=True, ground=None, level="full",
        radius=TILE_RX):
    if ground is None:
        ground = "#000" if palette == "red" else GROUND
    p = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
         f'width="{size}" height="{size}">']
    if tile:
        p.append(f'<rect width="100" height="100" rx="{radius:g}" fill="{ground}"/>')
    p += elements(palette, level)
    p.append("</g></svg>")
    return "\n".join(p)


def tile_body(palette="violet", ground=GROUND, level="full", radius=TILE_RX):
    """The rounded tile with the mark on it, as a fragment in the 100x100 frame."""
    return (f'<rect width="100" height="100" rx="{radius:g}" fill="{ground}"/>\n'
            + group(palette, level))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Emit the Trails mark as SVG.")
    ap.add_argument("--palette", default="violet", choices=sorted(PALETTES))
    ap.add_argument("--level", default="full", choices=sorted(LEVELS))
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--bare", action="store_true", help="no rounded tile")
    ap.add_argument("--ground", default=None,
                    help="tile color; default #0E0C16, #000 for the red colorway")
    ap.add_argument("--radius", type=float, default=TILE_RX)
    ap.add_argument("-o", "--out")
    args = ap.parse_args()
    out = svg(args.palette, args.size, not args.bare, args.ground, args.level,
              args.radius)
    if args.out:
        with open(args.out, "w") as f:
            f.write(out + "\n")
    else:
        print(out)
