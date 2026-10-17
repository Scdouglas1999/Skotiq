#!/usr/bin/env python3
"""Regenerate every brand asset from mark.py.

One procedural source emits every icon and image in the repo; nothing
downstream is edited by hand. Run from anywhere:

    python3 tools/brand/render.py all       # everything below
    python3 tools/brand/render.py masters   # assets/branding/*.svg
    python3 tools/brand/render.py icons     # platform icons (win/mac/linux/ios/android)
    python3 tools/brand/render.py web       # web app icons + run-watch SVGs
    python3 tools/brand/render.py readme    # repo images: logo, social preview, banners

rsvg-convert and ImageMagick 7 (`magick`) do the raster work. Runs are
deterministic: regenerating produces identical files.
"""

import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mark

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
BRANDING = os.path.join(ROOT, "assets", "branding")
FONT = os.path.join(ROOT, "tools", "brand", "fonts", "Sora[wght].ttf")

# The page ground behind the wordmark lockups; one step darker than the tile.
PAGE_GROUND = "#08070D"
WORDMARK_INK = "#ECE8F6"
WORDMARK_INK_LIGHT = "#2B2347"
BANNER_LIGHT_BG = "#F4F2FA"

WORDMARK = "skotiq"
TRACKING_EM = -0.04  # wordmark letter-spacing


def log(path):
    print(os.path.relpath(path, ROOT))


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    log(path)


def run(args, **kw):
    subprocess.run(args, check=True, **kw)


def rsvg(svg_text, out, width, height=None):
    """Rasterize an SVG string with rsvg-convert."""
    height = height or width
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
        tmp = f.name
    os.makedirs(os.path.dirname(out), exist_ok=True)
    try:
        run(["rsvg-convert", "-w", str(width), "-h", str(height), "-o", out, tmp])
    finally:
        os.unlink(tmp)
    log(out)


def rsvg_font_env():
    """fontconfig scope that sees Sora without installing it system-wide."""
    confdir = tempfile.mkdtemp(prefix="skotiq-fc-")
    cachedir = tempfile.mkdtemp(prefix="skotiq-fccache-")
    conf = os.path.join(confdir, "fonts.conf")
    with open(conf, "w") as f:
        f.write(
            '<?xml version="1.0"?>\n'
            '<!DOCTYPE fontconfig SYSTEM "fonts.dtd">\n'
            "<fontconfig>\n"
            '  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>\n'
            f"  <dir>{os.path.dirname(FONT)}</dir>\n"
            f"  <cachedir>{cachedir}</cachedir>\n"
            "</fontconfig>\n"
        )
    env = dict(os.environ)
    env["FONTCONFIG_FILE"] = conf
    return env


def rsvg_text(svg_text, out, width, height):
    """Rasterize an SVG that sets type in Sora (banners, social preview)."""
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
        tmp = f.name
    os.makedirs(os.path.dirname(out), exist_ok=True)
    try:
        run(["rsvg-convert", "-w", str(width), "-h", str(height), "-o", out, tmp],
            env=rsvg_font_env())
    finally:
        os.unlink(tmp)
    log(out)


def tile_png(out, px, palette="violet", level=None, ground=None,
             radius=mark.TILE_RX):
    """The rounded-tile icon rasterized at px, at the level for that size."""
    level = level or mark.level_for_size(px)
    rsvg(mark.svg(palette, size=px, tile=True, ground=ground, level=level,
                  radius=radius), out, px)


def wordmark_em_width():
    """The advance width of the wordmark, in em, at Sora SemiBold."""
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont
    font = TTFont(FONT)
    instantiateVariableFont(font, {"wght": 600})
    cmap, hmtx = font.getBestCmap(), font["hmtx"]
    adv = sum(hmtx[cmap[ord(c)]][0] for c in WORDMARK)
    return adv / font["head"].unitsPerEm


def lockup_svg(w, h, bg, palette, wordmark_fill, wordmark_px, mark_px,
               gap, tile_mark):
    """Centered [mark + wordmark] lockup on a solid ground.

    The wordmark sits at a fixed pixel size; its advance width (in em,
    tracking included) comes from the font so the group centers exactly."""
    em = wordmark_em_width()
    text_w = (em + TRACKING_EM * (len(WORDMARK) - 1)) * wordmark_px
    total = mark_px + gap + text_w
    mx = (w - total) / 2
    tx = mx + mark_px + gap
    cy = h / 2
    tile = ""
    if tile_mark:
        tile = mark.tile_body(palette)
    else:
        tile = mark.group(palette)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
        f'width="{w}" height="{h}">\n'
        f'<rect width="{w}" height="{h}" fill="{bg}"/>\n'
        f'<g transform="translate({mx:.2f} {cy - mark_px / 2:.2f}) '
        f'scale({mark_px / 100:.4f})">\n{tile}\n</g>\n'
        f'<text x="{tx:.2f}" y="{cy:.2f}" font-family="Sora" font-weight="600" '
        f'font-size="{wordmark_px}" letter-spacing="{TRACKING_EM}em" '
        f'fill="{wordmark_fill}" dominant-baseline="central">{WORDMARK}</text>\n'
        f"</svg>"
    )


# --- masters ----------------------------------------------------------------

def masters():
    """Committed master SVGs: the bare mark in each colorway, plus tiles."""
    for level in mark.LEVELS:
        for palette in ("violet", "light", "red", "mono"):
            write(os.path.join(BRANDING, f"mark-{level}-{palette}.svg"),
                  mark.svg(palette, tile=False, level=level) + "\n")
        write(os.path.join(BRANDING, f"icon-{level}.svg"),
              mark.svg("violet", level=level) + "\n")


# --- platform icons ---------------------------------------------------------

def ico(out):
    """Windows .ico: every frame drawn at its own level, never downscaled."""
    frames = [16, 20, 24, 32, 40, 48, 64, 256]
    with tempfile.TemporaryDirectory() as d:
        pngs = []
        for px in frames:
            p = os.path.join(d, f"f{px}.png")
            tile_png(p, px)
            pngs.append(p)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        run(["magick"] + pngs + [out])
    log(out)


def icons():
    # Windows
    ico(os.path.join(ROOT, "apps/desktop/windows/runner/resources/app_icon.ico"))

    # Linux: skotiq.png is the default lookup, skotiq_N.png the sized set.
    linux = os.path.join(ROOT, "apps/desktop/linux/icons")
    for px in (16, 32, 48, 64, 128, 256, 512):
        tile_png(os.path.join(linux, f"skotiq_{px}.png"), px)
    tile_png(os.path.join(linux, "skotiq.png"), 256)

    # macOS: Apple's icon grid — an 824 px rounded body on the 1024 canvas,
    # transparent margin. Level follows the body's rendered size.
    mac = os.path.join(ROOT, "apps/desktop/macos/Runner/Assets.xcassets",
                       "AppIcon.appiconset")
    for px in (16, 32, 64, 128, 256, 512, 1024):
        body = px * mark.MACOS_BODY
        level = mark.level_for_size(body)
        # The 100-unit tile fragment scales into the 824 px body.
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
            f'width="{px}" height="{px}">\n'
            f'<g transform="translate(100 100) scale(8.24)">\n'
            f'{mark.tile_body("violet", level=level)}\n</g>\n</svg>'
        )
        rsvg(svg, os.path.join(mac, f"app_icon_{px}.png"), px)

    # iOS: full-bleed square tiles (iOS applies its own mask), no alpha.
    ios = os.path.join(ROOT, "apps/mobile/ios/Runner/Assets.xcassets",
                       "AppIcon.appiconset")
    for name, px in [
        ("Icon-App-20x20@1x.png", 20), ("Icon-App-20x20@2x.png", 40),
        ("Icon-App-20x20@3x.png", 60), ("Icon-App-29x29@1x.png", 29),
        ("Icon-App-29x29@2x.png", 58), ("Icon-App-29x29@3x.png", 87),
        ("Icon-App-40x40@1x.png", 40), ("Icon-App-40x40@2x.png", 80),
        ("Icon-App-40x40@3x.png", 120), ("Icon-App-60x60@2x.png", 120),
        ("Icon-App-60x60@3x.png", 180), ("Icon-App-76x76@1x.png", 76),
        ("Icon-App-76x76@2x.png", 152), ("Icon-App-83.5x83.5@2x.png", 167),
        ("Icon-App-1024x1024@1x.png", 1024),
    ]:
        tile_png(os.path.join(ios, name), px, radius=0)
        # iOS wants opaque RGB tiles; PNG24 drops the alpha channel outright.
        run(["magick", os.path.join(ios, name), "-strip",
             f"PNG24:{os.path.join(ios, name)}"])

    android_icons()


def vector_paths(palette, level, k, tx, ty):
    """The mark's geometry baked into the Android vector's 108dp viewport."""
    lanes, width, _, dot = mark.LEVELS[level]
    out = []
    for (o, s, e), c in zip(lanes, mark.lane_colors(palette, level)):
        out.append((mark.lane_mapped(o, s, e, k * 1.08, tx - 4.0 * k,
                                     ty - 4.54 * k), "stroke", c,
                    width * k * 1.08))
    if dot:
        cx, cy, r = mark.CX * k * 1.08 + tx - 4.0 * k, \
            mark.CY_UP * k * 1.08 + ty - 4.54 * k, dot * k * 1.08
        d = (f"M{cx - r:.2f},{cy:.2f} a{r:.2f},{r:.2f} 0 1,1 {2 * r:.2f},0 "
             f"a{r:.2f},{r:.2f} 0 1,1 {-2 * r:.2f},0 Z")
        out.append((d, "fill", mark.pole_color(palette), 0))
    return out


def vector_xml(palette, level, k, tx, ty):
    """An Android vector drawable of the mark, transform baked flat.

    pathData is the same lane geometry mark.py emits, pre-multiplied by the
    placement transform because VectorDrawable strokes round differently than
    SVG under nested group scales."""
    p = ['<vector xmlns:android="http://schemas.android.com/apk/res/android"',
         '    android:width="108dp" android:height="108dp"',
         '    android:viewportWidth="108" android:viewportHeight="108">']
    for d, kind, color, w in vector_paths(palette, level, k, tx, ty):
        if kind == "stroke":
            p.append(f'    <path android:pathData="{d}" android:fillColor="#00000000" '
                     f'android:strokeColor="{color}" android:strokeWidth="{w:.2f}" '
                     f'android:strokeLineCap="round"/>')
        else:
            p.append(f'    <path android:pathData="{d}" android:fillColor="{color}"/>')
    p.append("</vector>")
    return "\n".join(p) + "\n"


def android_icons():
    res = os.path.join(ROOT, "apps/mobile/android/app/src/main/res")

    # Legacy launcher icons (API < 26): the rounded tile on transparency.
    for dpi, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                    ("xxhdpi", 144), ("xxxhdpi", 192)):
        tile_png(os.path.join(res, f"mipmap-{dpi}", "ic_launcher.png"), px)

    # Adaptive icon (API 26+): #0E0C16 ground behind a foreground that keeps
    # the mark inside the 66dp safe zone of the 108dp canvas.
    write(os.path.join(res, "mipmap-anydpi-v26", "ic_launcher.xml"),
          '<?xml version="1.0" encoding="utf-8"?>\n'
          '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <background android:drawable="@color/ic_launcher_background"/>\n'
          '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
          '    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n'
          '</adaptive-icon>\n')

    write(os.path.join(res, "values", "ic_launcher_background.xml"),
          '<?xml version="1.0" encoding="utf-8"?>\n'
          '<resources>\n'
          '    <color name="ic_launcher_background">#0E0C16</color>\n'
          '</resources>\n')

    # The mark occupies the safe zone: scale the 100-unit frame to 66 of 108.
    pad = (108.0 - 66.0) / 2.0
    write(os.path.join(res, "drawable", "ic_launcher_foreground.xml"),
          vector_xml("violet", "full", mark.ADAPTIVE_SAFE, pad, pad))

    # Android 13 themed icons tint this layer themselves, so it is drawn
    # in a single flat color.
    lanes, width, _, dot = mark.LEVELS["full"]
    p = ['<vector xmlns:android="http://schemas.android.com/apk/res/android"',
         '    android:width="108dp" android:height="108dp"',
         '    android:viewportWidth="108" android:viewportHeight="108">']
    for d, kind, _, w in vector_paths("mono", "full", mark.ADAPTIVE_SAFE, pad, pad):
        if kind == "stroke":
            p.append(f'    <path android:pathData="{d}" android:fillColor="#00000000" '
                     f'android:strokeColor="#FFFFFFFF" android:strokeWidth="{w:.2f}" '
                     f'android:strokeLineCap="round"/>')
        else:
            p.append(f'    <path android:pathData="{d}" android:fillColor="#FFFFFFFF"/>')
    p.append("</vector>")
    write(os.path.join(res, "drawable", "ic_launcher_monochrome.xml"),
          "\n".join(p) + "\n")


# --- web --------------------------------------------------------------------

def maskable_svg(palette="violet", level="full", ground=mark.GROUND,
                 safe=mark.MASKABLE_SAFE):
    """Full-bleed ground; the mark scaled into the centered safe zone."""
    inset = (100.0 - 100.0 * safe) / 2.0
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
        'width="512" height="512">\n'
        f'<rect width="100" height="100" fill="{ground}"/>\n'
        f'<g transform="translate({inset:g} {inset:g}) scale({safe:g})">\n'
        f'{mark.group(palette, level)}\n</g>\n</svg>'
    )


def web():
    webdir = os.path.join(ROOT, "apps/desktop/web")
    # favicon.png is the 16px browser tab icon.
    tile_png(os.path.join(webdir, "favicon.png"), 16)

    icons_dir = os.path.join(webdir, "icons")
    for px in (192, 512):
        tile_png(os.path.join(icons_dir, f"Icon-{px}.png"), px)
        # Maskable: full-bleed ground, mark inside the 80% safe circle.
        rsvg(maskable_svg(level="full"),
             os.path.join(icons_dir, f"Icon-maskable-{px}.png"), px)

    # Run-watch PWA icons stay SVG; the sized ones double as maskable.
    rw = os.path.join(ROOT, "apps/desktop/web_run_watch/icons")
    write(os.path.join(rw, "icon.svg"),
          mark.svg("violet", level="full").replace(
              "<svg ", '<svg role="img" aria-label="Skotiq" ', 1) + "\n")
    for px in (192, 512):
        write(os.path.join(rw, f"icon-{px}.svg"),
              maskable_svg().replace(
                  "<svg ", '<svg role="img" aria-label="Skotiq" ', 1)
              .replace('width="512" height="512"',
                       f'width="{px}" height="{px}"') + "\n")


# --- repo images ------------------------------------------------------------

def readme():
    # The tile icon, referenced by docs and packaging.
    tile_png(os.path.join(BRANDING, "logo-512.png"), 512)

    # Social preview: tile mark + wordmark on the page ground, 1280x640.
    rsvg_text(lockup_svg(1280, 640, PAGE_GROUND, "violet", WORDMARK_INK,
                         wordmark_px=210, mark_px=360, gap=96, tile_mark=True),
              os.path.join(BRANDING, "social-preview.png"), 1280, 640)

    # README banners, 1280x400: bare mark + wordmark, dark and light grounds.
    rsvg_text(lockup_svg(1280, 400, PAGE_GROUND, "violet", WORDMARK_INK,
                         wordmark_px=150, mark_px=230, gap=72, tile_mark=False),
              os.path.join(BRANDING, "banner.png"), 1280, 400)
    rsvg_text(lockup_svg(1280, 400, BANNER_LIGHT_BG, "light", WORDMARK_INK_LIGHT,
                         wordmark_px=150, mark_px=230, gap=72, tile_mark=False),
              os.path.join(BRANDING, "banner-light.png"), 1280, 400)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("group", choices=["masters", "icons", "web", "readme", "all"])
    args = ap.parse_args()
    groups = {"masters": masters, "icons": icons, "web": web, "readme": readme}
    if args.group == "all":
        for fn in groups.values():
            fn()
    else:
        groups[args.group]()


if __name__ == "__main__":
    main()
