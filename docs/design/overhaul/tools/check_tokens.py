#!/usr/bin/env python3
"""Validate design-tokens.json and emit mockups/tokens.css.

Run from anywhere:  python3 docs/design/overhaul/tools/check_tokens.py

What it checks (exit code 1 on any failure):
  * every text role (textPrimary/textSecondary/textMuted) clears WCAG AA 4.5:1
    on EVERY surface of its palette (bg, surface, well, surfaceHover,
    surfaceElevated, surfaceOverlay);
  * every status role (success/warning/error/info) clears 4.5:1 on every
    surface, because the app reads them as small status TEXT;
  * onPrimary clears 4.5:1 on primary and accent (filled buttons);
  * primary clears 4.5:1 on bg and surface (used as link/selected text);
  * brandWarm clears 3:1 on every surface — it is a brand/decoration GRAPHIC
    (WCAG 1.4.11 non-text floor), never text and never a status colour;
  * brandWarm stays visibly distinct from warning: CIEDE2000 DeltaE >= 15,
    so a decoration can never read as a caution;
  * the three text roles stay strictly ordered (primary brighter than
    secondary brighter than muted on dark palettes; reverse on light);
  * red night keeps red as the dominant channel of every text/status colour.

The numbers it prints are the numbers to quote in code comments.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
TOKENS = ROOT / "design-tokens.json"
CSS_OUT = ROOT / "mockups" / "tokens.css"

SURFACES = ["bg", "surface", "well", "surfaceHover", "surfaceElevated", "surfaceOverlay"]
TEXT_ROLES = ["textPrimary", "textSecondary", "textMuted"]
STATUS_ROLES = ["success", "warning", "error", "info"]
AA = 4.5
# WCAG 1.4.11 floor for non-text graphics (the mark's warm lane, the "now"
# marker) and the minimum CIEDE2000 separation between brandWarm and warning
# that keeps a decoration from reading as a caution.
NON_TEXT_AA = 3.0
BRAND_WARM_MIN_DELTA_E = 15.0


def hex_to_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def luminance(h: str) -> float:
    def chan(c: int) -> float:
        c1 = c / 255
        return c1 / 12.92 if c1 <= 0.03928 else ((c1 + 0.055) / 1.055) ** 2.4

    r, g, b = hex_to_rgb(h)
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def _lab(h: str) -> tuple[float, float, float]:
    """sRGB hex -> CIE L*a*b* (D65/2°)."""
    import math

    def chan(c: int) -> float:
        c1 = c / 255
        return c1 / 12.92 if c1 <= 0.03928 else ((c1 + 0.055) / 1.055) ** 2.4

    r, g, b = hex_to_rgb(h)
    x = (0.4124564 * chan(r) + 0.3575761 * chan(g) + 0.1804375 * chan(b)) / 0.95047
    y = 0.2126729 * chan(r) + 0.7151522 * chan(g) + 0.0721750 * chan(b)
    z = (0.0193339 * chan(r) + 0.1191920 * chan(g) + 0.9503041 * chan(b)) / 1.08883

    def f(t: float) -> float:
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116

    fx, fy, fz = f(x), f(y), f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def delta_e_00(h1: str, h2: str) -> float:
    """CIEDE2000 DeltaE between two sRGB hex colours."""
    import math

    l1, a1, b1 = _lab(h1)
    l2, a2, b2 = _lab(h2)
    c1, c2 = math.hypot(a1, b1), math.hypot(a2, b2)
    cb = (c1 + c2) / 2
    g = 0.5 * (1 - math.sqrt(cb**7 / (cb**7 + 25**7))) if cb else 0
    a1p, a2p = a1 * (1 + g), a2 * (1 + g)
    c1p, c2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360 if c1p else 0
    h2p = math.degrees(math.atan2(b2, a2p)) % 360 if c2p else 0
    dlp = l2 - l1
    dcp = c2p - c1p
    dhp = 0.0
    if c1p * c2p:
        d = h2p - h1p
        if d > 180:
            d -= 360
        elif d < -180:
            d += 360
        dhp = d
    dhp2 = 2 * math.sqrt(c1p * c2p) * math.sin(math.radians(dhp / 2))
    lbp, cbp = (l1 + l2) / 2, (c1p + c2p) / 2
    if c1p * c2p:
        if abs(h1p - h2p) <= 180:
            hbp = (h1p + h2p) / 2
        elif h1p + h2p < 360:
            hbp = (h1p + h2p + 360) / 2
        else:
            hbp = (h1p + h2p - 360) / 2
    else:
        hbp = h1p + h2p
    t = (
        1
        - 0.17 * math.cos(math.radians(hbp - 30))
        + 0.24 * math.cos(math.radians(2 * hbp))
        + 0.32 * math.cos(math.radians(3 * hbp + 6))
        - 0.20 * math.cos(math.radians(4 * hbp - 63))
    )
    dro = 30 * math.exp(-(((hbp - 275) / 25) ** 2))
    rc = 2 * math.sqrt(cbp**7 / (cbp**7 + 25**7))
    sl = 1 + 0.015 * ((lbp - 50) ** 2) / math.sqrt(20 + (lbp - 50) ** 2)
    sc = 1 + 0.045 * cbp
    sh = 1 + 0.015 * cbp * t
    rt = -math.sin(math.radians(2 * dro)) * rc
    return math.sqrt(
        (dlp / sl) ** 2 + (dcp / sc) ** 2 + (dhp2 / sh) ** 2 + rt * (dcp / sc) * (dhp2 / sh)
    )


def main() -> int:
    tokens = json.loads(TOKENS.read_text())
    failures: list[str] = []
    print(f"design-tokens.json v{tokens['version']}\n")

    for name, p in tokens["palettes"].items():
        print(f"== {name} ==")
        worst: dict[str, tuple[float, str]] = {}
        for role in TEXT_ROLES + STATUS_ROLES:
            for s in SURFACES:
                c = contrast(p[role], p[s])
                if role not in worst or c < worst[role][0]:
                    worst[role] = (c, s)
                if c < AA:
                    failures.append(f"{name}: {role} {p[role]} on {s} {p[s]} = {c:.2f}:1 (< {AA})")
        for role, (c, s) in worst.items():
            flag = "" if c >= AA else "  <-- FAIL"
            print(f"  {role:14s} worst {c:5.2f}:1 on {s}{flag}")

        for fill in ("primary", "accent"):
            c = contrast(p["onPrimary"], p[fill])
            flag = "" if c >= AA else "  <-- FAIL"
            print(f"  onPrimary on {fill:8s} {c:5.2f}:1{flag}")
            if c < AA:
                failures.append(f"{name}: onPrimary on {fill} = {c:.2f}:1")
        for s in ("bg", "surface"):
            c = contrast(p["primary"], p[s])
            flag = "" if c >= AA else "  <-- FAIL"
            print(f"  primary as text on {s:8s} {c:5.2f}:1{flag}")
            if c < AA:
                failures.append(f"{name}: primary as text on {s} = {c:.2f}:1")

        c = contrast(p["onStart"], p["startFill"])
        flag = "" if c >= AA else "  <-- FAIL"
        print(f"  onStart on startFill  {c:5.2f}:1{flag}")
        if c < AA:
            failures.append(f"{name}: onStart on startFill = {c:.2f}:1")

        # brandWarm is a brand/decoration colour — it must never read as a
        # status, so it gets the non-text 3:1 floor on every surface and a
        # minimum CIEDE2000 distance from this palette's `warning`.
        warm = p["brandWarm"]
        worst_warm = min(contrast(warm, p[s]) for s in SURFACES)
        worst_surface = min(SURFACES, key=lambda s: contrast(warm, p[s]))
        flag = "" if worst_warm >= NON_TEXT_AA else "  <-- FAIL"
        print(
            f"  brandWarm graphic  {worst_warm:5.2f}:1 worst on {worst_surface}{flag}"
        )
        if worst_warm < NON_TEXT_AA:
            failures.append(
                f"{name}: brandWarm {warm} on {worst_surface} = {worst_warm:.2f}:1 (< {NON_TEXT_AA})"
            )
        de = delta_e_00(warm, p["warning"])
        flag = "" if de >= BRAND_WARM_MIN_DELTA_E else "  <-- FAIL"
        print(f"  brandWarm vs warning dE00 {de:5.2f} (min {BRAND_WARM_MIN_DELTA_E:.0f}){flag}")
        if de < BRAND_WARM_MIN_DELTA_E:
            failures.append(
                f"{name}: brandWarm {warm} is {de:.2f} dE00 from warning "
                f"{p['warning']} (< {BRAND_WARM_MIN_DELTA_E})"
            )
        for sw in p.get("accentSwatches", []):
            ink = "#0B0D12" if luminance(sw) > 0.1791 else "#FFFFFF"   # SkotiqColors._prefersDarkInk
            c_fill = contrast(ink, sw)
            c_text = min(contrast(sw, p["bg"]), contrast(sw, p["surface"]))
            flag = "" if (c_fill >= AA and c_text >= AA) else "  <-- FAIL"
            print(f"  swatch {sw}: ink {c_fill:5.2f}:1, as text {c_text:5.2f}:1{flag}")
            if c_fill < AA:
                failures.append(f"{name}: swatch {sw} ink contrast {c_fill:.2f}:1")
            if c_text < AA:
                failures.append(f"{name}: swatch {sw} as link text {c_text:.2f}:1")

        lp, ls, lm = (luminance(p[r]) for r in TEXT_ROLES)
        ordered = (lp > ls > lm) if luminance(p["bg"]) < 0.5 else (lp < ls < lm)
        print(f"  text ladder ordered: {'yes' if ordered else 'NO  <-- FAIL'}")
        if not ordered:
            failures.append(f"{name}: text roles not strictly ordered")

        if p.get("isRedNight"):
            for role in TEXT_ROLES + STATUS_ROLES + ["primary", "accent", "startFill", "brandWarm"] + [f"bands.{k}" for k in p["bands"]]:
                if role.startswith("bands."):
                    r, g, b = hex_to_rgb(p["bands"][role[6:]])
                    if not (r >= g and r >= b and g == b):
                        failures.append(f"{name}: {role} is not on the red axis")
                    continue
                r, g, b = hex_to_rgb(p[role])
                if not (r > g and r > b and g == b):
                    failures.append(f"{name}: {role} {p[role]} is not on the red axis (G must equal B, R dominant)")
            print("  red-axis check done")
        print()

    css = emit_css(tokens)
    CSS_OUT.parent.mkdir(parents=True, exist_ok=True)
    CSS_OUT.write_text(css)
    print(f"wrote {CSS_OUT.relative_to(ROOT.parent.parent.parent)} ({len(css)} bytes)")

    if failures:
        print("\nFAILURES:")
        for f in failures:
            print("  - " + f)
        return 1
    print("\nall checks passed")
    return 0


def emit_css(tokens: dict) -> str:
    out = ["/* GENERATED by tools/check_tokens.py from design-tokens.json. Do not edit by hand. */"]
    for name, p in tokens["palettes"].items():
        selector = ":root" if name == "dark" else f'[data-theme="{name}"]'
        out.append(f"{selector} {{")
        for k, v in p.items():
            if isinstance(v, (bool, list, dict)):
                continue
            out.append(f"  --{k}: {v};")
        for k, v in p.get("bands", {}).items():
            out.append(f"  --band-{k}: {v};")
        for role in ("success", "warning", "error"):
            r, g, b = hex_to_rgb(p[role])
            out.append(f"  --{role}-rgb: {r}, {g}, {b};")
        r, g, b = hex_to_rgb(p["primary"])
        out.append(f"  --primary-rgb: {r}, {g}, {b};")
        r, g, b = hex_to_rgb(p["surface"])
        out.append(f"  --surface-rgb: {r}, {g}, {b};")
        out.append("}")
    out.append(":root {")
    for k, v in tokens["space"].items():
        out.append(f"  --space-{k}: {v}px;")
    for k, v in tokens["radius"].items():
        out.append(f"  --radius-{k}: {v}px;")
    for k, v in tokens["shell"].items():
        out.append(f"  --shell-{k}: {v}px;")
    m = tokens["motion"]
    out.append(f"  --motion-hover: {m['hoverMs']}ms {m['easing']};")
    out.append(f"  --motion-state: {m['stateMs']}ms {m['easing']};")
    out.append(f"  --motion-panel: {m['panelMs']}ms {m['easing']};")
    for k, v in tokens["opacity"].items():
        out.append(f"  --opacity-{k}: {v};")
    out.append("}")
    for name, st in tokens["typography"]["styles"].items():
        fam = "var(--font-mono)" if st["family"] == "mono" else "var(--font-sans)"
        out.append(f".t-{name} {{ font-family: {fam}; font-size: {st['size']}px; font-weight: {st['weight']}; line-height: {st['lineHeight']}; letter-spacing: {st['letterSpacing']}px;"
                   + (" text-transform: uppercase;" if st.get("uppercase") else "")
                   + (" font-variant-numeric: tabular-nums;" if st.get("tabular") else "")
                   + " }")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    sys.exit(main())
