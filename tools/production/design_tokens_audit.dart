import 'dart:io';

/// Design-system token-adoption tracker for the app's screen layer.
///
/// Scans `packages/skotiq_app/lib/screens` for the three highest-volume
/// hand-rolled style smells that bypass the `skotiq_ui` design system:
///
///   * `BorderRadius.circular(<n>)`  — should use `SkotiqTokens.radius*` /
///     `SkotiqTokens.borderRadius*`.
///   * inline `TextStyle(fontSize: ...)` literals AND `.copyWith(fontSize:)`
///     on a named style — should use the `SkotiqTypography` scale
///     (display, pageTitle, sectionTitle, eyebrow, body*, readout*, button*).
///   * raw `Colors.<name>` usages — should use `SkotiqColors.of(context)`.
///     Raw Material colors are the worst offenders because they DO NOT invert
///     under red-night mode and break dark-adaptation in the field.
///
/// This is an incremental-migration TRACKER, not a hard gate. The full
/// migration is a deliberate, reviewable, look-preserving effort — never a
/// blind mass replace. The script reports per-category counts and the
/// worst-offending files so the migration can be driven down over time and
/// regressions (count growth) can be caught in review.
///
/// The TextStyle count jumped from 23 to 2,160 in the Observatory wave-0
/// commit and no code was added: the scan was line-at-a-time, and `dart format`
/// breaks nearly every one of these constructors across lines, so it had been
/// reporting roughly one percent of what was there — while this very comment
/// said "~2780 inline TextStyles across the app". The count is now taken over
/// the whole file (2,145 `TextStyle(fontSize:)` plus 15 `.copyWith(fontSize:)`
/// in the screen layer), which is the number the prose always claimed. The
/// radius count going 4 -> 0 in the same commit IS a real migration.
///
/// Exit behavior:
///   * Default (informational): always exits 0 — safe for CI, never blocks.
///   * `--max-radii=N`, `--max-textstyles=N`, `--max-colors=N`: exit 1 if the
///     corresponding category count EXCEEDS the given budget. Opt-in enforcement
///     for ratcheting the counts down (set a budget at-or-above the current
///     count, then lower it as the migration progresses).
///   * `--strict`: shorthand that treats any nonzero count as a failure
///     (exit 1). Useful once a category reaches zero to prevent reintroduction.
///   * `--root=<path>`: override the scan root (default
///     `packages/skotiq_app/lib/screens`).
///
/// Usage:
///   dart run tools/production/design_tokens_audit.dart
///   dart run tools/production/design_tokens_audit.dart --max-colors=0
///   melos run audit:design-tokens
void main(List<String> args) {
  final options = _Options.parse(args);

  final rootDir = Directory(options.root);
  if (!rootDir.existsSync()) {
    stderr.writeln('design-tokens-audit: scan root not found: ${options.root}');
    exit(2);
  }

  // BorderRadius.circular(<numeric literal>) — flags hardcoded corner radii.
  // Matches an int or double literal argument; ignores token/variable args
  // like `BorderRadius.circular(SkotiqTokens.radiusMd)`.
  final radiiPattern = RegExp(r'BorderRadius\.circular\(\s*\d+(?:\.\d+)?\s*\)');

  // Inline TextStyle(...) that carries a fontSize, and `.copyWith(fontSize:)`
  // on a named style.
  //
  // `.copyWith(color:)` is the sanctioned recolor and is not flagged. Resizing
  // is a different act: it takes a style that IS a named role and makes it a
  // size that is not on the scale, which is the same magic number the
  // constructor form carries, only harder to grep for. The Observatory scale
  // forbids both (docs/design/overhaul/03-tokens.md §2) — there are no other
  // sizes, and a role that needs a different size is a different role.
  //
  // The non-greedy body stops at the first `fontSize:` within the call, and
  // `dotAll` lets it cross newlines: `dart format` breaks nearly every one of
  // these across lines, so a line-at-a-time scan saw almost none of them. This
  // one is therefore run over the whole file rather than line by line, with
  // the line number recovered from the match offset.
  final textStylePattern = RegExp(
    r'(?:TextStyle|\.copyWith)\((?:[^()]|\([^()]*\))*?fontSize:',
    dotAll: true,
  );

  // Raw Material `Colors.<name>` (e.g. Colors.white, Colors.red). Excludes
  // `SkotiqColors` (different identifier) via the leading word boundary
  // that won't match the `Colors` inside `SkotiqColors`.
  final colorsPattern = RegExp(r'(?<![A-Za-z0-9_])Colors\.[a-zA-Z]');

  final radiiHits = <_Hit>[];
  final textStyleHits = <_Hit>[];
  final colorsHits = <_Hit>[];

  final dartFiles =
      rootDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.endsWith('.g.dart'))
          .where((f) => !f.path.endsWith('.freezed.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in dartFiles) {
    final relPath = file.path.replaceAll('\\', '/');
    final lines = file.readAsLinesSync();
    // The comment-stripped source, one line per line, so an offset in it maps
    // straight back to a line number.
    final stripped = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // Skip line comments so a documented example doesn't inflate the count.
      final code = _stripLineComment(line);
      stripped.add(code);
      if (code.trim().isEmpty) continue;

      for (final _ in radiiPattern.allMatches(code)) {
        radiiHits.add(_Hit(relPath, i + 1, line.trim()));
      }
      for (final _ in colorsPattern.allMatches(code)) {
        colorsHits.add(_Hit(relPath, i + 1, line.trim()));
      }
    }

    final source = stripped.join('\n');
    for (final match in textStylePattern.allMatches(source)) {
      final line = '\n'.allMatches(source.substring(0, match.start)).length;
      textStyleHits.add(_Hit(relPath, line + 1, lines[line].trim()));
    }
  }

  _printReport(
    root: options.root,
    fileCount: dartFiles.length,
    radii: radiiHits,
    textStyles: textStyleHits,
    colors: colorsHits,
  );

  final failures = <String>[];
  void check(String label, int count, int? budget) {
    if (budget == null) return;
    if (count > budget) {
      failures.add(
        '$label: $count exceeds budget $budget (over by ${count - budget})',
      );
    }
  }

  if (options.strict) {
    if (radiiHits.isNotEmpty) {
      failures.add('hardcoded radii: ${radiiHits.length} (strict: expected 0)');
    }
    if (textStyleHits.isNotEmpty) {
      failures.add(
        'inline TextStyle(fontSize:): ${textStyleHits.length} (strict: expected 0)',
      );
    }
    if (colorsHits.isNotEmpty) {
      failures.add(
        'raw Colors.* usages: ${colorsHits.length} (strict: expected 0)',
      );
    }
  } else {
    check('hardcoded radii', radiiHits.length, options.maxRadii);
    check(
      'inline TextStyle(fontSize:)',
      textStyleHits.length,
      options.maxTextStyles,
    );
    check('raw Colors.* usages', colorsHits.length, options.maxColors);
  }

  if (failures.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('design-tokens-audit: FAIL');
    for (final f in failures) {
      stdout.writeln('  - $f');
    }
    exit(1);
  }

  stdout.writeln('');
  stdout.writeln(
    'design-tokens-audit: informational only (no budget exceeded). '
    'Pass --max-radii=N / --max-textstyles=N / --max-colors=N or --strict to enforce.',
  );
  exit(0);
}

/// Strips a trailing `//` line comment, but only when the `//` is not inside a
/// string literal. Keeps the scan from flagging documented examples while not
/// mangling URLs like `https://` inside a string.
String _stripLineComment(String line) {
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < line.length - 1; i++) {
    final c = line[i];
    if (c == "'" && !inDouble) inSingle = !inSingle;
    if (c == '"' && !inSingle) inDouble = !inDouble;
    if (!inSingle && !inDouble && c == '/' && line[i + 1] == '/') {
      return line.substring(0, i);
    }
  }
  return line;
}

void _printReport({
  required String root,
  required int fileCount,
  required List<_Hit> radii,
  required List<_Hit> textStyles,
  required List<_Hit> colors,
}) {
  stdout.writeln('================================================');
  stdout.writeln('Design-system token adoption tracker');
  stdout.writeln('scan root : $root');
  stdout.writeln('dart files: $fileCount');
  stdout.writeln('================================================');
  _printCategory(
    'Hardcoded BorderRadius.circular(<n>)',
    radii,
    'use SkotiqTokens.radius* / SkotiqTokens.borderRadius*',
  );
  _printCategory(
    'Inline TextStyle(fontSize:) and .copyWith(fontSize:)',
    textStyles,
    'use the SkotiqTypography scale (h1..h6, body*, label*, mono*)',
  );
  _printCategory(
    'Raw Colors.<name> usages (break red-night mode)',
    colors,
    'use SkotiqColors.of(context).<semantic>',
  );
  stdout.writeln('------------------------------------------------');
  stdout.writeln(
    'TOTAL flagged: '
    '${radii.length + textStyles.length + colors.length} '
    '(radii ${radii.length}, textStyles ${textStyles.length}, colors ${colors.length})',
  );
}

void _printCategory(String title, List<_Hit> hits, String guidance) {
  stdout.writeln('');
  stdout.writeln('• $title');
  stdout.writeln('  count: ${hits.length}');
  stdout.writeln('  fix  : $guidance');
  if (hits.isEmpty) return;

  // Per-file rollup, worst offenders first — guides where to migrate next.
  final byFile = <String, int>{};
  for (final h in hits) {
    byFile[h.path] = (byFile[h.path] ?? 0) + 1;
  }
  final ranked = byFile.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final top = ranked.take(8);
  stdout.writeln('  top files:');
  for (final e in top) {
    stdout.writeln('    ${e.value.toString().padLeft(4)}  ${e.key}');
  }
  if (ranked.length > 8) {
    stdout.writeln('    ... and ${ranked.length - 8} more files');
  }
}

class _Hit {
  final String path;
  final int line;
  final String text;
  const _Hit(this.path, this.line, this.text);
}

class _Options {
  final String root;
  final int? maxRadii;
  final int? maxTextStyles;
  final int? maxColors;
  final bool strict;

  const _Options({
    required this.root,
    required this.maxRadii,
    required this.maxTextStyles,
    required this.maxColors,
    required this.strict,
  });

  static _Options parse(List<String> args) {
    var root = 'packages/skotiq_app/lib/screens';
    int? maxRadii;
    int? maxTextStyles;
    int? maxColors;
    var strict = false;

    int? intArg(String value, String flag) {
      final parsed = int.tryParse(value);
      if (parsed == null || parsed < 0) {
        stderr.writeln(
          'design-tokens-audit: invalid value for $flag: "$value"',
        );
        exit(2);
      }
      return parsed;
    }

    for (final arg in args) {
      if (arg == '--strict') {
        strict = true;
      } else if (arg.startsWith('--root=')) {
        root = arg.substring('--root='.length);
      } else if (arg.startsWith('--max-radii=')) {
        maxRadii = intArg(arg.substring('--max-radii='.length), '--max-radii');
      } else if (arg.startsWith('--max-textstyles=')) {
        maxTextStyles = intArg(
          arg.substring('--max-textstyles='.length),
          '--max-textstyles',
        );
      } else if (arg.startsWith('--max-colors=')) {
        maxColors = intArg(
          arg.substring('--max-colors='.length),
          '--max-colors',
        );
      } else {
        stderr.writeln('design-tokens-audit: unknown argument: $arg');
        exit(2);
      }
    }

    return _Options(
      root: root,
      maxRadii: maxRadii,
      maxTextStyles: maxTextStyles,
      maxColors: maxColors,
      strict: strict,
    );
  }
}
