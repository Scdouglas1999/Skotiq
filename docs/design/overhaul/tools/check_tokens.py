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
            for role in TEXT_ROLES + STATUS_ROLES + ["primary", "accent", "startFill"] + [f"bands.{k}" for k in p["bands"]]:
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
