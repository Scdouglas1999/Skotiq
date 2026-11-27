// Narrative / audit-trail comment audit.
//
// Flags comments that read like a PR-justification or change-history narrative
// rather than an explanation of a current, non-obvious invariant. The classic
// shapes this catches:
//
//   * "X used to live in N places, now consolidated here" (refactor history)
//   * "previously / historically / formerly / prior to this change ..."
//   * "this is intentional because the agent ..." (AI self-narration)
//   * multi-line "why this import" justifications on a single import line
//   * inline restatement of what the next line of code obviously does
//     ("// Create a controller", "// Get the source profile", ...)
//
// Scope: Dart library code (`apps/*/lib`, `packages/*/lib`, tests excluded)
// and every Rust file under `native/skotiq_native` except `target/` and the
// generated bridge (tests included: Rust keeps them beside the code).
//
// It is a counted gate: the Dart and the Rust finding counts may not exceed
// the two numbers in $_defaultBaselinePath (first line Dart, second Rust).
// Lower a number when findings go away, never raise it to pass. Most hits are
// judgement calls; a line whose history is the contract (an external wire
// format) can be kept with an `--allowlist` file of path:line[:exact_text].
//
// Usage:
//   dart run tools/production/narrative_comment_audit.dart
//   dart run tools/production/narrative_comment_audit.dart --out-hits .narrative_hits.txt
//   dart run tools/production/narrative_comment_audit.dart --max <N> --max-rust <N>
//   dart run tools/production/narrative_comment_audit.dart --self-test <dir>

import 'dart:convert';
import 'dart:io';

const _scanRoots = <String>['apps', 'packages'];
const _rustRoot = 'native/skotiq_native';
const _defaultHitsPath = '.narrative_hits.txt';
const _defaultBaselinePath = 'tools/production/narrative_comment_baseline.txt';

const _excludedSubstrings = <String>[
  '/frb_generated.',
  '.g.dart',
  '.freezed.dart',
];

const _excludedDirectoryNames = <String>{
  '.dart_tool',
  '.git',
  '.worktrees',
  'build',
  'target',
  'coverage',
  'generated',
  'test',
  'tests',
  'example',
  'samples',
};

final _libPathPatterns = <RegExp>[
  RegExp(r'^apps/[^/]+/lib/'),
  RegExp(r'^packages/[^/]+/lib/'),
];

// A comment line is any line whose first non-space content is `//`, `///` or
// (Rust) `//!`. Group 1 = the slashes, group 2 = the comment body.
final _commentLine = RegExp(r'^\s*(//[/!]?)\s?(.*)$');

// ---------------------------------------------------------------------------
// Category 1 — change-history / refactor narrative.
// These describe how the code came to be, not what invariant it now upholds.
// Almost always trimmable; keep only when the history IS the contract (e.g. an
// external protocol that "historically emitted X").
// ---------------------------------------------------------------------------
final _historyPattern = RegExp(
  r'\bused to (be|do|have|live|return|call|run|draw|own|sit|reach)\b|'
  r'\bpreviously\b|\bformerly\b|\bin the past\b|\bhistorically\b|'
  r'\bprior to (this|the)\b|\bbefore this (change|version|wire-?up|patch)\b|'
  r'\bthis (replaces|was (a |the )?(refactor|rename|moved|split|extracted))\b|'
  r'\bwe (no longer|used to)\b|\bduplicat\w+ .*\b(used to|now)\b|'
  r'\bthat used to be (re-?derived|duplicated|scattered|inlined)\b|'
  r'\bre-?derived in (two|three|four|five|\d+|several|multiple) places\b|'
  r'\bscattered (across|toggles|in)\b',
  caseSensitive: false,
);

// ---------------------------------------------------------------------------
// Category 2 — AI self-narration / PR-justification framing.
// "this is intentional because the agent...", "to be clear", "note to
// reviewer", "matches the established precedent in ...". Trimmable: an
// invariant should be stated as a fact, not defended to a reviewer.
// ---------------------------------------------------------------------------
final _selfNarrationPattern = RegExp(
  r'\bthe agent\b|\bas part of the (audit|refactor|pass|sweep|cleanup)\b|'
  r'\bnote to (self|reviewer|future|the reader)\b|\bfuture reader\b|'
  // "to be clear," / "just to be clear" as a sentence opener is reviewer-speak;
  // the trailing comma avoids matching prose like "expected to be clear (cloud
  // at or below ...)".
  r'(^|[.;]\s*)(just )?to be clear,|\bjust to be safe\b|'
  r'\bmatches the established\b.*\bprecedent\b|'
  r'\bper the (review|audit|pr|spec) (request|comment|note)\b|'
  // A rule's source is the rule, stated; not the task that asked for it.
  r"\bthe brief's\b|\b(from|follows?|match(es)?|in|per) the brief\b(?! window)|"
  r'\bthe brief (asks|says|calls|notes|explicitly|default|promises|singles|is)\b|'
  r'\(the brief\)|\bthe brief(?=[.,;:])|'
  r'\bde-?slop\b|\banti-?slop\b',
  caseSensitive: false,
);

// ---------------------------------------------------------------------------
// Category 3 — restating-the-obvious inline comments. A comment that just
// narrates the verb of the next statement ("// Create a controller",
// "// Get the source profile", "// Set the framing target"). Trimmable when it
// adds nothing the identifier on the next line doesn't already say.
// We require the comment to be a near-verbatim "<Verb> the <noun>" with no
// "because/so/why" clause (which would make it explanatory, not narrative).
// ---------------------------------------------------------------------------
final _restateObviousPattern = RegExp(
  r'^(create|get|set|build|loop over|iterate (over|through)|increment|'
  r'add|remove|update|return|call|make|instantiate|construct|wrap|fetch)\b'
  r'(?!.*\b(because|so that|so we|to avoid|otherwise|which|since|"|`|note:|'
  r'must|never|always|invariant|caller|backend|wire|protocol)\b).{0,60}$',
  caseSensitive: false,
);

class _Finding {
  _Finding(this.path, this.line, this.text, this.category);
  final String path;
  final int line;
  final String text;
  final String category;

  String get entry => '$path:$line:$text';
}

void main(List<String> args) {
  if (args.contains('--self-test')) {
    final dir = _argValue(args, '--self-test');
    if (dir == null) {
      stderr.writeln('--self-test requires a directory argument');
      exit(2);
    }
    _runSelfTest(dir);
    return;
  }

  final hitsPath = _argValue(args, '--out-hits') ?? _defaultHitsPath;
  final allowlistPath = _argValue(args, '--allowlist');
  final baseline = _readBaseline();
  final maxArg = _argValue(args, '--max') ?? baseline?.dart;
  final maxRustArg = _argValue(args, '--max-rust') ?? baseline?.rust;

  final allowlist = allowlistPath == null
      ? const <_AllowlistEntry>[]
      : _loadAllowlist(allowlistPath);
  final workspaceRoot = _normalize(Directory.current.absolute.path);
  final findings = <_Finding>[];
  var filesScanned = 0;

  for (final root in _scanRoots) {
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) {
      continue;
    }
    for (final entity in rootDir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final rel = _toWorkspaceRelative(entity.path, workspaceRoot);
      if (!_isLibPath(rel) || _shouldSkip(rel) || rel.endsWith('_test.dart')) {
        continue;
      }
      filesScanned++;
      _scanFile(entity, rel, findings);
    }
  }
  final rustFindings = <_Finding>[];
  var rustFilesScanned = 0;
  final rustDir = Directory(_rustRoot);
  if (rustDir.existsSync()) {
    for (final entity in rustDir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith('.rs')) continue;
      final rel = _toWorkspaceRelative(entity.path, workspaceRoot);
      if (_isSkippedRust(rel)) continue;
      rustFilesScanned++;
      _scanFile(entity, rel, rustFindings, rust: true);
    }
  }

  final kept =
      findings.where((f) => !_isAllowlisted(f.entry, allowlist)).toList()
        ..sort((a, b) => a.entry.compareTo(b.entry));
  final keptRust =
      rustFindings.where((f) => !_isAllowlisted(f.entry, allowlist)).toList()
        ..sort((a, b) => a.entry.compareTo(b.entry));

  final byCat = <String, int>{};
  for (final f in kept) {
    byCat[f.category] = (byCat[f.category] ?? 0) + 1;
  }

  final rustByCat = <String, int>{};
  for (final f in keptRust) {
    rustByCat[f.category] = (rustByCat[f.category] ?? 0) + 1;
  }

  _writeTextFile(
    hitsPath,
    '${[...kept, ...keptRust].map((f) => '${f.category}\t${f.entry}').join('\n')}\n',
  );

  stdout.writeln('Narrative-comment audit complete.');
  stdout.writeln(
    'Scanned $filesScanned Dart files, $rustFilesScanned Rust files',
  );
  stdout.writeln('Dart findings: ${kept.length} -> $hitsPath');
  byCat.forEach((cat, n) => stdout.writeln('  $cat: $n'));
  stdout.writeln('Rust findings: ${keptRust.length} -> $hitsPath');
  rustByCat.forEach((cat, n) => stdout.writeln('  $cat: $n'));

  final overDart = _over('Dart', kept.length, maxArg, '--max');
  final overRust = _over('Rust', keptRust.length, maxRustArg, '--max-rust');
  if (overDart || overRust) exit(1);
}

/// Whether [count] exceeds the limit [maxArg] (none when null), saying so.
bool _over(String language, int count, String? maxArg, String flag) {
  if (maxArg == null) return false;
  final max = int.tryParse(maxArg);
  if (max == null) {
    stderr.writeln('Invalid $flag value: $maxArg');
    exit(2);
  }
  if (count <= max) return false;
  stderr.writeln(
    '$language narrative findings $count exceed $max: remove the new ones '
    '(see the hits file) rather than raising the baseline.',
  );
  return true;
}

/// The finding counts the tree may not exceed, from [_defaultBaselinePath]:
/// the first line is Dart's, the second Rust's. Null when the file is absent
/// (a self-test tree or another checkout).
({String? dart, String? rust})? _readBaseline() {
  final file = File(_defaultBaselinePath);
  if (!file.existsSync()) return null;
  final lines = file
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  return (
    dart: lines.isNotEmpty ? lines[0] : null,
    rust: lines.length > 1 ? lines[1] : null,
  );
}

/// Rust files the audit leaves out: build output and the generated bridge.
bool _isSkippedRust(String path) =>
    path.split('/').contains('target') || path.contains('frb_generated');

void _scanFile(File file, String rel, List<_Finding> out, {bool rust = false}) {
  final lines = _readLinesSafe(file);
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final m = _commentLine.firstMatch(raw);
    if (m == null) {
      continue;
    }
    final isDoc = (m.group(1) ?? '') != '//';
    final body = (m.group(2) ?? '').trim();
    if (body.isEmpty) {
      continue;
    }
    final cat = _classify(body, isDoc: isDoc, nextLine: _nextCode(lines, i));
    if (cat == null) {
      continue;
    }
    out.add(_Finding(rel, i + 1, raw.trimRight(), cat));
  }
  if (!rust) _scanImportJustifications(lines, rel, out);
}

// Category 4 — over-written "why this import" block. A contiguous run of plain
// `//` comment lines (> [_importBlockThreshold]) sitting directly above an
// `import`/`export` statement is the stack_result_screen.dart smell: a
// paragraph defending one import line. A short note ("// ignore: …" or a
// one-liner) is fine; a multi-sentence justification belongs in design docs or
// next to the seam it describes, not pinned to every consumer's import block.
// This is a *block-level* signal that the per-line classifier misses because
// the tell ("Matches the established … precedent in …") is line-wrapped.
const _importBlockThreshold = 3;

void _scanImportJustifications(
  List<String> lines,
  String rel,
  List<_Finding> out,
) {
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    if (!t.startsWith('import ') && !t.startsWith('export ')) {
      continue;
    }
    // Walk upward over a contiguous plain-`//` comment block (skip a lone
    // `// ignore:` directive immediately above the import — that's mandatory).
    var top = i - 1;
    while (top >= 0) {
      final c = lines[top].trim();
      if (c.startsWith('// ignore:')) {
        top--;
        continue;
      }
      if (c.startsWith('//') && !c.startsWith('///')) {
        top--;
        continue;
      }
      break;
    }
    final blockStart = top + 1;
    var prose = 0;
    for (var j = blockStart; j < i; j++) {
      final c = lines[j].trim();
      if (c.startsWith('//') && !c.startsWith('// ignore:')) {
        prose++;
      }
    }
    if (prose > _importBlockThreshold) {
      out.add(
        _Finding(
          rel,
          blockStart + 1,
          '${lines[blockStart].trimRight()}  [+${prose - 1} more lines '
              'justifying import on L${i + 1}]',
          'import-justification',
        ),
      );
    }
  }
}

// The next non-blank, non-comment line after [index] (a real statement), or ''.
String _nextCode(List<String> lines, int index) {
  for (var j = index + 1; j < lines.length; j++) {
    final t = lines[j].trim();
    if (t.isEmpty || t.startsWith('//')) {
      continue;
    }
    return t;
  }
  return '';
}

// History/self-narration are evaluated on body alone (they are smells in doc
// comments too). "restates-obvious" is only flagged for a plain `//` comment
// whose *next* line is an actual code statement — that excludes doc comments,
// region/section headers, and route-list banners that merely happen to start
// with a verb.
String? _classify(
  String body, {
  required bool isDoc,
  required String nextLine,
}) {
  if (_selfNarrationPattern.hasMatch(body)) {
    return 'self-narration';
  }
  if (_historyPattern.hasMatch(body)) {
    return 'change-history';
  }
  if (!isDoc &&
      nextLine.isNotEmpty &&
      _looksLikeStatement(nextLine) &&
      _restateObviousPattern.hasMatch(body)) {
    return 'restates-obvious';
  }
  return null;
}

// A heuristic "this is executable code, not a declaration header": ends in `;`,
// or opens/continues an expression (`(`, `{` with assignment, `=`, `=>`,
// `await`, `return`, `final`/`var`/`const` local). Excludes class/enum/method
// signatures and `case`/region labels which usually precede such comments by
// accident.
bool _looksLikeStatement(String line) {
  if (line.startsWith('case ') ||
      line.startsWith('class ') ||
      line.startsWith('enum ') ||
      line.startsWith('@') ||
      line.startsWith('GET ') ||
      line.startsWith('POST ')) {
    return false;
  }
  return line.endsWith(';') ||
      line.contains('=') ||
      line.contains('=>') ||
      line.startsWith('await ') ||
      line.startsWith('return ') ||
      RegExp(r'^(final|var|const|let)\b').hasMatch(line) ||
      RegExp(r'\b\w+\s*\(').hasMatch(line);
}

// --------------------------------------------------------------------------
// Self-test: build a tiny fixture tree, run the classifier, assert it flags
// the slop shapes and spares the legitimate invariant comments.
// --------------------------------------------------------------------------
void _runSelfTest(String dir) {
  final cases = <String, String?>{
    // change-history
    'a duplicate inline A..F mapping used to live here.': 'change-history',
    'Historically these were scattered across four files.': 'change-history',
    'Prior to this version a connected safety monitor had to be set.':
        'change-history',
    'that used to be re-derived in four places.': 'change-history',
    'We used to run a full discoverDevices sweep.': 'change-history',
    // self-narration
    'this is intentional because the agent split the seam.': 'self-narration',
    'Matches the established // ignore precedent in stacking_panel.dart.':
        'self-narration',
    'Added as part of the audit sweep.': 'self-narration',
    'Defaults follow the brief: 30 s.': 'self-narration',
    'The record keeps the brief the builder was given.': null,
    // restates-obvious
    'Create a controller for the stream': 'restates-obvious',
    'Get the source profile to derive a name for the copy': 'restates-obvious',
    'Set the framing target': 'restates-obvious',
    // legitimate keepers — MUST stay null
    'PHD2 emits "LostStar"; the bridge canonicalizes it to lostStar.': null,
    'Skip the precondition because a stale discovery cache must not '
            'reject a known-good reconnect.':
        null,
    'Clamp to >=1 so the integrator never divides by zero.': null,
    'Get the focal point because the caller scales around it.': null,
    'Throughput, not latency: batch writes to avoid fsync per row.': null,
  };

  var failures = 0;
  cases.forEach((body, expected) {
    // Classifier cases are evaluated as plain `//` comments whose next line is
    // a statement, so restate-obvious can fire; history/self-narration ignore
    // both. The restate keepers in the fixture carry a "because/caller" clause
    // that the pattern's negative-lookahead already rejects.
    final got = _classify(body, isDoc: false, nextLine: 'final x = 1;');
    if (got != expected) {
      failures++;
      stderr.writeln('FAIL classify("$body") => $got, expected $expected');
    }
  });

  // Also exercise the directory walk + allowlist on a real temp tree.
  final tmp = Directory('$dir/narrative_selftest')..createSync(recursive: true);
  final pkgLib = Directory('${tmp.path}/packages/x/lib')
    ..createSync(recursive: true);
  File('${pkgLib.path}/sample.dart').writeAsStringSync('''
// Create a controller for the stream
final c = StreamController();
// PHD2 emits "LostStar" historically; the bridge canonicalizes it.
final x = 1;
''');
  final hits = <_Finding>[];
  _scanFile(
    File('${pkgLib.path}/sample.dart'),
    'packages/x/lib/sample.dart',
    hits,
  );
  // Both the restate-obvious AND the change-history phrasing match; the second
  // is a legitimate keeper, so confirm the allowlist removes exactly it.
  const allowEntry =
      'packages/x/lib/sample.dart:3:// PHD2 emits "LostStar" historically; '
      'the bridge canonicalizes it.';
  final allow = _loadAllowlistFromLines(<String>[allowEntry]);
  final kept = hits.where((f) => !_isAllowlisted(f.entry, allow)).toList();
  if (kept.length != 1 || kept.first.category != 'restates-obvious') {
    failures++;
    stderr.writeln(
      'FAIL walk+allowlist: expected 1 restates-obvious hit, '
      'got ${kept.map((f) => '${f.category}@${f.line}').toList()}',
    );
  }

  // Import-justification block: a 4-line `//` paragraph above an import must be
  // flagged once (at the block top); a single-line note + `// ignore:` must not.
  File('${pkgLib.path}/imports.dart').writeAsStringSync('''
// The seam owns the colour stretch (native bridge only exposes mono);
// the companion is the per-channel STF that matches the capture path.
// Not re-exported through the barrel, so the viewer reaches it directly.
// (Matches the established precedent in stacking_panel.dart.)
// ignore: implementation_imports
import 'package:x/src/seam.dart';
// short, fine
import 'package:x/ok.dart';
''');
  final importHits = <_Finding>[];
  _scanFile(
    File('${pkgLib.path}/imports.dart'),
    'packages/x/lib/imports.dart',
    importHits,
  );
  final justifications = importHits
      .where((f) => f.category == 'import-justification')
      .toList();
  if (justifications.length != 1 || justifications.first.line != 1) {
    failures++;
    stderr.writeln(
      'FAIL import-justification: expected 1 hit at L1, got '
      '${justifications.map((f) => 'L${f.line}').toList()}',
    );
  }

  // A Rust file: `//!` and `///` are doc comments, `use` blocks are not
  // checked for import justifications.
  File('${tmp.path}/sample.rs').writeAsStringSync('''
//! Previously the module lived in two crates.
// Set the framing target
let target = frame();
''');
  final rustHits = <_Finding>[];
  _scanFile(
    File('${tmp.path}/sample.rs'),
    'native/x/sample.rs',
    rustHits,
    rust: true,
  );
  final rustCategories = rustHits
      .map((f) => '${f.category}@${f.line}')
      .toList();
  if (rustCategories.join(',') != 'change-history@1,restates-obvious@2') {
    failures++;
    stderr.writeln('FAIL rust walk: got $rustCategories');
  }

  tmp.deleteSync(recursive: true);

  if (failures == 0) {
    stdout.writeln(
      'narrative_comment_audit self-test: PASS (${cases.length} '
      'classifier cases + walk/allowlist)',
    );
  } else {
    stderr.writeln('narrative_comment_audit self-test: $failures FAILURES');
    exit(1);
  }
}

// --------------------------------------------------------------------------
// Allowlist (path:line[:exact_text]) — same granular format as the placeholder
// audit so an entry can never silently whitelist a whole file.
// --------------------------------------------------------------------------
class _AllowlistEntry {
  _AllowlistEntry(this.path, this.line, this.exactText);
  final String path;
  final int line;
  final String? exactText;
}

List<_AllowlistEntry> _loadAllowlist(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return const <_AllowlistEntry>[];
  }
  return _loadAllowlistFromLines(file.readAsLinesSync());
}

List<_AllowlistEntry> _loadAllowlistFromLines(List<String> rawLines) {
  final entries = <_AllowlistEntry>[];
  for (final rawLine in rawLines) {
    final raw = rawLine.trim();
    if (raw.isEmpty || raw.startsWith('#')) {
      continue;
    }
    final normalized = _normalize(raw);
    final firstColon = normalized.indexOf(':');
    if (firstColon < 0) {
      stderr.writeln('Invalid allowlist entry "$raw": need path:line.');
      exit(2);
    }
    final secondColon = normalized.indexOf(':', firstColon + 1);
    final pathPart = normalized.substring(0, firstColon);
    final String linePart;
    final String? textPart;
    if (secondColon < 0) {
      linePart = normalized.substring(firstColon + 1);
      textPart = null;
    } else {
      linePart = normalized.substring(firstColon + 1, secondColon);
      textPart = normalized.substring(secondColon + 1);
    }
    final lineNo = int.tryParse(linePart);
    if (lineNo == null) {
      stderr.writeln('Invalid allowlist entry "$raw": bad line number.');
      exit(2);
    }
    entries.add(_AllowlistEntry(pathPart, lineNo, textPart));
  }
  return entries;
}

bool _isAllowlisted(String entry, List<_AllowlistEntry> allowlist) {
  if (allowlist.isEmpty) {
    return false;
  }
  final normalized = _normalize(entry);
  final firstColon = normalized.indexOf(':');
  final secondColon = firstColon >= 0
      ? normalized.indexOf(':', firstColon + 1)
      : -1;
  if (firstColon < 0 || secondColon < 0) {
    return false;
  }
  final entryPath = normalized.substring(0, firstColon);
  final entryLineNo = int.tryParse(
    normalized.substring(firstColon + 1, secondColon),
  );
  final entryText = normalized.substring(secondColon + 1);
  if (entryLineNo == null) {
    return false;
  }
  for (final c in allowlist) {
    if (c.path != entryPath || c.line != entryLineNo) {
      continue;
    }
    if (c.exactText == null || c.exactText == entryText) {
      return true;
    }
  }
  return false;
}

// --------------------------------------------------------------------------
// Path / IO helpers (mirrors placeholder_audit.dart conventions).
// --------------------------------------------------------------------------
String? _argValue(List<String> args, String key) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == key && i + 1 < args.length) {
      return args[i + 1];
    }
    if (args[i].startsWith('$key=')) {
      return args[i].substring(key.length + 1);
    }
  }
  return null;
}

bool _isLibPath(String path) => _libPathPatterns.any((p) => p.hasMatch(path));

bool _shouldSkip(String path) {
  final segments = path.split('/');
  for (final s in segments) {
    if (_excludedDirectoryNames.contains(s)) {
      return true;
    }
  }
  return _excludedSubstrings.any(path.contains);
}

List<String> _readLinesSafe(File file) {
  try {
    return const LineSplitter().convert(file.readAsStringSync());
  } catch (_) {
    try {
      return const LineSplitter().convert(
        utf8.decode(file.readAsBytesSync(), allowMalformed: true),
      );
    } catch (_) {
      return const <String>[];
    }
  }
}

void _writeTextFile(String path, String content) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

String _normalize(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');

String _toWorkspaceRelative(String path, String workspaceRoot) {
  final absolute = _normalize(File(path).absolute.path);
  if (absolute.toLowerCase().startsWith(workspaceRoot.toLowerCase())) {
    final start = workspaceRoot.endsWith('/')
        ? workspaceRoot.length
        : workspaceRoot.length + 1;
    if (absolute.length >= start) {
      return absolute.substring(start);
    }
  }
  return _normalize(path);
}
