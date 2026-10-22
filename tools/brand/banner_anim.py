#!/usr/bin/env python3
"""Animated README banner — the Trails mark's app motions rendered as a GIF.

The frames reproduce the widget's motion math exactly: the startup `draw`
pass (lanes staggered 90 ms under cubic-bezier(.22,.7,.2,1), the pole star's
overshoot pop), a settle beat, then one `working` glint sweep — the same
skotiq_mark.dart -> TrailsMotion timings the splash and run-state marks use.
Partial arcs ride SVG's pathLength normalization, so dash offsets here are
the same path fractions the CustomPainter extracts.

Timeline per loop: draw (0-1596 ms) -> still (1596-2400 ms) ->
working glint (2400-5000 ms) -> repeat. 20 fps, ~5 s.

Usage:
    python3 tools/brand/banner_anim.py            # dark + light GIFs
    python3 tools/brand/banner_anim.py --dark-only --fps 20
"""

import argparse
import math
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mark
import render

# --- motion constants, ported from TrailsMotion (skotiq_mark.dart) ---------

DRAW_STAGGER_MS = 90
DRAW_LANE_MS = 1176
DRAW_POLE_START_MS = 1092
DRAW_POLE_PEAK_MS = 1386
DRAW_POLE_SETTLE_MS = 1596
DRAW_POLE_OVERSHOOT = 1.25
DRAW_CURVE = (0.22, 0.7, 0.2, 1)      # cubic-bezier(.22,.7,.2,1)

WORKING_CYCLE_MS = 2600
GLINT_DASH = 0.10                     # fraction of path length
GLINT_STROKE = 1.6                    # viewBox units
GLINT_PEAK = 0.75
GLINT_CURVE = (0.45, 0, 0.25, 1)      # cubic-bezier(.45,0,.25,1)
GLINT_TRAVEL_END = 0.88
GLINT_COLOR = "#FFFFFF"

SETTLE_MS = 2400                       # end of the still beat between draw and glint
LOOP_MS = 5000                         # full loop length


def cubic_bezier(x1, y1, x2, y2):
    """CSS cubic-bezier(x1,y1,x2,y2): x -> eased y, via Newton + bisection."""
    def sample(a, b, c, t):
        return ((a * t + b) * t + c) * t

    ax, bx = 3 * x1 - 3 * x2 + 1, -6 * x1 + 3 * x2
    cx = 3 * x1
    ay, by = 3 * y1 - 3 * y2 + 1, -6 * y1 + 3 * y2
    cy = 3 * y1

    def at(x):
        t = x
        for _ in range(8):
            err = sample(ax, bx, cx, t) - x
            if abs(err) < 1e-6:
                return sample(ay, by, cy, t)
            d = (3 * ax * t + 2 * bx) * t + cx
            if abs(d) < 1e-6:
                break
            t -= err / d
        lo, hi = 0.0, 1.0
        while hi - lo > 1e-6:
            t = (lo + hi) / 2
            if sample(ax, bx, cx, t) < x:
                lo = t
            else:
                hi = t
        return sample(ay, by, cy, t)
    return at


DRAW_EASE = cubic_bezier(*DRAW_CURVE)
GLINT_EASE = cubic_bezier(*GLINT_CURVE)


def ease_out(t):
    """Flutter's Curves.easeOut ≈ cubic-bezier(0,0,.58,1); close enough that
    the pole pop's shape is indistinguishable at banner scale."""
    return cubic_bezier(0.0, 0.0, 0.58, 1.0)(t)


def draw_lane_fraction(index, ms):
    u = max(0.0, min(1.0, (ms - index * DRAW_STAGGER_MS) / DRAW_LANE_MS))
    if u <= 0 or u >= 1:
        return u
    return DRAW_EASE(u)


def draw_pole(ms):
    if ms <= DRAW_POLE_START_MS:
        return 0.0, 0.0
    if ms <= DRAW_POLE_PEAK_MS:
        u = ease_out((ms - DRAW_POLE_START_MS) /
                     (DRAW_POLE_PEAK_MS - DRAW_POLE_START_MS))
        return DRAW_POLE_OVERSHOOT * u, u
    if ms <= DRAW_POLE_SETTLE_MS:
        u = ease_out((ms - DRAW_POLE_PEAK_MS) /
                     (DRAW_POLE_SETTLE_MS - DRAW_POLE_PEAK_MS))
        return DRAW_POLE_OVERSHOOT - (DRAW_POLE_OVERSHOOT - 1) * u, 1.0
    return 1.0, 1.0


def glint_opacity(t):
    if t <= 0.12:
        return GLINT_PEAK * GLINT_EASE(t / 0.12)
    if t <= 0.70:
        return GLINT_PEAK
    if t <= GLINT_TRAVEL_END:
        return GLINT_PEAK * (1 - GLINT_EASE(
            (t - 0.70) / (GLINT_TRAVEL_END - 0.70)))
    return 0.0


def glint_start(t):
    u = min(1.0, t / GLINT_TRAVEL_END)
    return (1.05 * GLINT_EASE(u) - 0.1) % 1.0


# --- frame composition ------------------------------------------------------

def lane_path(offset, up_start, lo_end):
    """mark.lane() plus pathLength so dash offsets are path fractions."""
    d = mark.lane(offset, up_start, lo_end)
    return d


def frame_mark(palette, ms):
    """The mark group at loop position ms (bare mark, no tile)."""
    lanes, width, pick, dot = mark.LEVELS["full"]
    colors = mark.lane_colors(palette, "full")
    out = []
    if ms < DRAW_POLE_SETTLE_MS:
        # Draw pass: each lane revealed to its eased fraction.
        for i, ((o, s, e), c) in enumerate(zip(lanes, colors)):
            f = draw_lane_fraction(i, ms)
            if f <= 0:
                continue
            if f >= 1:
                dash = ""
            else:
                dash = (f' pathLength="100" stroke-dasharray="100 100" '
                        f'stroke-dashoffset="{100 * (1 - f):.2f}"')
            out.append(f'<path d="{lane_path(o, s, e)}" fill="none" stroke="{c}" '
                       f'stroke-width="{width}" stroke-linecap="round"{dash}/>')
        scale, opacity = draw_pole(ms)
        if dot and scale > 0 and opacity > 0:
            out.append(f'<g transform="translate({mark.CX} {mark.CY_UP}) '
                       f'scale({scale:.3f})"><circle r="{dot}" '
                       f'fill="{mark.pole_color(palette)}" '
                       f'opacity="{opacity:.3f}"/></g>')
    elif ms < SETTLE_MS:
        # Still mark between the draw and the glint.
        for (o, s, e), c in zip(lanes, colors):
            out.append(f'<path d="{lane_path(o, s, e)}" fill="none" stroke="{c}" '
                       f'stroke-width="{width}" stroke-linecap="round"/>')
        if dot:
            out.append(f'<circle cx="{mark.CX}" cy="{mark.CY_UP}" r="{dot}" '
                       f'fill="{mark.pole_color(palette)}"/>')
    else:
        # Working pass: still mark plus the synced white glint.
        for (o, s, e), c in zip(lanes, colors):
            out.append(f'<path d="{lane_path(o, s, e)}" fill="none" stroke="{c}" '
                       f'stroke-width="{width}" stroke-linecap="round"/>')
        t = (ms - SETTLE_MS) / WORKING_CYCLE_MS
        op = glint_opacity(t)
        if op > 0:
            start = glint_start(t)
            off = (100 - start * 100) % 100
            for (o, s, e) in lanes:
                out.append(
                    f'<path d="{lane_path(o, s, e)}" fill="none" '
                    f'stroke="{GLINT_COLOR}" stroke-opacity="{op:.3f}" '
                    f'stroke-width="{GLINT_STROKE}" stroke-linecap="round" '
                    f'pathLength="100" stroke-dasharray="{GLINT_DASH * 100:g} '
                    f'{100 - GLINT_DASH * 100:g}" stroke-dashoffset="{off:.2f}"/>')
        if dot:
            out.append(f'<circle cx="{mark.CX}" cy="{mark.CY_UP}" r="{dot}" '
                       f'fill="{mark.pole_color(palette)}"/>')
    return "\n".join(out)


def frame_svg(w, h, ms, dark=True):
    """One banner frame: the animated mark left of the static wordmark,
    laid out like render.lockup_svg (1280x400, mark 230, gap 72, text 150)."""
    bg = render.PAGE_GROUND if dark else render.BANNER_LIGHT_BG
    palette = "violet" if dark else "light"
    ink = render.WORDMARK_INK if dark else render.WORDMARK_INK_LIGHT
    mark_px, gap, wordmark_px = 230, 72, 150
    em = render.wordmark_em_width()
    text_w = (em + render.TRACKING_EM * (len(render.WORDMARK) - 1)) * wordmark_px
    total = mark_px + gap + text_w
    mx = (w - total) / 2
    tx = mx + mark_px + gap
    cy = h / 2
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
        f'width="{w}" height="{h}">\n'
        f'<rect width="{w}" height="{h}" fill="{bg}"/>\n'
        f'<g transform="translate({mx:.2f} {cy - mark_px / 2:.2f}) '
        f'scale({mark_px / 100:.4f})">\n'
        f'<g transform="{mark.MARK_TRANSFORM}">\n{frame_mark(palette, ms)}\n</g>\n'
        f"</g>\n"
        f'<text x="{tx:.2f}" y="{cy:.2f}" font-family="Sora" font-weight="600" '
        f'font-size="{wordmark_px}" letter-spacing="{render.TRACKING_EM}em" '
        f'fill="{ink}" dominant-baseline="central">{render.WORDMARK}</text>\n'
        f"</svg>"
    )


def render_gif(out, dark, width, height, fps):
    """Render the loop's frames and assemble the GIF."""
    step = 1000 // fps
    times = list(range(0, LOOP_MS, step))
    delay_cs = round(step / 10)
    with tempfile.TemporaryDirectory(prefix="skotiq-banner-") as d:
        frames = []
        for i, ms in enumerate(times):
            png = os.path.join(d, f"f{i:03d}.png")
            svg = frame_svg(1280, 400, ms, dark=dark)
            with tempfile.NamedTemporaryFile("w", suffix=".svg",
                                             delete=False) as f:
                f.write(svg)
                tmp = f.name
            try:
                render.run(["rsvg-convert", "-w", str(width), "-h", str(height),
                            "-o", png, tmp], env=render.rsvg_font_env())
            finally:
                os.unlink(tmp)
            frames.append(png)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        render.run(["magick", "-delay", str(delay_cs), "-loop", "0"] + frames +
                   ["-layers", "Optimize", out])
    render.log(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fps", type=int, default=20)
    ap.add_argument("--width", type=int, default=960)
    ap.add_argument("--height", type=int, default=300)
    ap.add_argument("--dark-only", action="store_true")
    args = ap.parse_args()
    render_gif(os.path.join(render.BRANDING, "banner.gif"), True,
               args.width, args.height, args.fps)
    if not args.dark_only:
        render_gif(os.path.join(render.BRANDING, "banner-light.gif"), False,
                   args.width, args.height, args.fps)


if __name__ == "__main__":
    main()
