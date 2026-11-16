"""Builds packages/skotiq_ui/assets/fonts/SkotiqSymbols-Regular.ttf.

The UI faces (Hanken Grotesk, Spline Sans Mono, Sora) have no Greek, superscript
signs, arrows, geometric shapes or symbols such as the e⁻ of a read-noise figure or
the ▸ of a menu path. Without a bundled face for them each platform draws them from
whatever system font it has, and a machine without one draws a box. This takes those
blocks from the Noto fonts (SIL Open Font License 1.1) and merges them into one
face that the typography lists as a fallback.

Run: python3 tools/fonts/build_skotiq_symbols.py [noto font dir]   (needs fontTools)
"""
import sys
from pathlib import Path

from fontTools import subset
from fontTools.merge import Merger
from fontTools.ttLib import TTFont

NOTO = Path(sys.argv[1] if len(sys.argv) > 1 else '/usr/share/fonts/noto')
OUT = Path(__file__).resolve().parents[2] / 'packages/skotiq_ui/assets/fonts/SkotiqSymbols-Regular.ttf'


def span(first, last):
    return list(range(first, last + 1))


COPYRIGHT = ('Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic, '
             'https://github.com/notofonts/symbols); Copyright 2022 Google LLC (Noto Sans Math)')

# Earlier sources win where blocks overlap.
SOURCES = [
    ('NotoSans-Regular.ttf',
     span(0x02B0, 0x02FF) + span(0x0370, 0x03FF) + span(0x2000, 0x206F)
     + span(0x2070, 0x209F) + span(0x2100, 0x214F)),
    ('NotoSansMath-Regular.ttf',
     span(0x2190, 0x21FF) + span(0x25A0, 0x25FF) + [0x2605, 0x2606]),
    ('NotoSansSymbols-Regular.ttf', span(0x2460, 0x24FF)),
    ('NotoSansSymbols2-Regular.ttf', span(0x2300, 0x23FF) + span(0x2600, 0x26FF)),
]


def main():
    taken = set()
    parts = []
    for name, codepoints in SOURCES:
        font = TTFont(NOTO / name)
        wanted = [c for c in codepoints if c in font.getBestCmap() and c not in taken]
        taken.update(wanted)
        options = subset.Options()
        # Single characters need no shaping, and the merge needs the parts' tables to agree.
        options.layout_features = []
        options.drop_tables += ['GSUB', 'GPOS', 'GDEF', 'MATH', 'vhea', 'vmtx', 'DSIG']
        options.hinting = False
        options.notdef_outline = True
        subsetter = subset.Subsetter(options)
        subsetter.populate(unicodes=wanted)
        subsetter.subset(font)
        # Fields the merge requires to match; they describe the whole family, not a glyph.
        font['head'].flags = 0b11
        font['head'].fontRevision = 1.0
        font['OS/2'].version = 4
        font['OS/2'].fsType = 0
        font['OS/2'].usWinAscent, font['OS/2'].usWinDescent = 1100, 400
        path = OUT.with_name(f'.part-{name}')
        font.save(path)
        parts.append(path)
    merged = Merger().merge([str(p) for p in parts])
    for p in parts:
        p.unlink()
    names = merged['name']
    for record in list(names.names):
        if record.nameID in (0, 1, 3, 4, 6, 16, 17):
            names.removeNames(nameID=record.nameID)
    names.setName(COPYRIGHT, 0, 3, 1, 0x409)
    names.setName('Skotiq Symbols', 1, 3, 1, 0x409)
    names.setName('Regular', 2, 3, 1, 0x409)
    names.setName('Skotiq Symbols Regular', 3, 3, 1, 0x409)
    names.setName('Skotiq Symbols Regular', 4, 3, 1, 0x409)
    names.setName('SkotiqSymbols-Regular', 6, 3, 1, 0x409)
    merged.save(OUT)
    print(OUT, len(taken), 'characters')


if __name__ == '__main__':
    main()
