#!/usr/bin/env python3
"""Reject visual literals in UI consumers; design definitions own these values."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[4]
TREES = (
    'packages/skotiq_app/lib', 'apps/desktop/lib', 'apps/mobile/lib',
    'packages/skotiq_ui/lib', 'packages/skotiq_planetarium/lib/src/widgets',
    'packages/skotiq_updater/lib',
)
# Print layouts use PDF points, and the mark defines approved brand artwork.
EXCLUDED = (
    'packages/skotiq_ui/lib/src/theme/',
    'packages/skotiq_ui/lib/src/components/brand/',
    'packages/skotiq_app/lib/services/observation_report_service.dart',
    'packages/skotiq_app/lib/services/finder_chart_service.dart',
)
RULES = {
    'local slider recipe': re.compile(r'\bSliderThemeData\('),
    'literal font family': re.compile(r"\bfontFamily:\s*['\"]"),
    'literal color': re.compile(r'\bColor\(\s*(?:0x[\dA-Fa-f]+|\d+)\s*\)|\bColors\.(?!transparent\b)\w+'),
    'literal corner radius': re.compile(r'\b(?:Border)?Radius\.circular\(\s*(?:\d|[^)\n]*[?:]\s*\d)'),
    'literal font size': re.compile(r'\bfontSize:\s*(?:\d|[^,\n)]*\?\s*\d|[^,\n)]*\?[^,\n)]*:\s*\d)'),
    'fixed palette override': re.compile(r'extensions:\s*(?:<[^>]+>)?\[\s*SkotiqColors\.(?:dark|light)\b'),
}

def violations(source):
    # Preserve lines for diagnostics while ignoring comments and their examples.
    source = re.sub(r'/\*.*?\*/|//[^\n]*',
                    lambda m: '\n' * m[0].count('\n'), source, flags=re.S)
    return [(source.count('\n', 0, match.start()) + 1, name)
            for name, pattern in RULES.items() for match in pattern.finditer(source)]

def main():
    failures = []
    count = 0
    for tree in TREES:
        directory = ROOT / tree
        if not directory.is_dir():
            raise RuntimeError(f'Missing UI tree: {tree}')
        for path in sorted(directory.rglob('*.dart')):
            relative = path.relative_to(ROOT).as_posix()
            if relative.startswith(EXCLUDED):
                continue
            count += 1
            failures.extend(f'{relative}:{line}: {rule}'
                            for line, rule in violations(path.read_text()))
    if failures:
        print('\n'.join(failures))
    print(f'UI token audit: {count} files, {len(failures)} violations')
    return bool(failures)

if __name__ == '__main__':
    sys.exit(main())
