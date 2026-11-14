import 'dart:convert';
import 'dart:io';

import 'audit_scope.dart';
import 'site_register.dart';

class BehavioralRule {
  final String id;
  final RegExp regex;
  final String summary;
  final bool highRisk;
  // Languages this rule applies to. Empty set = all supported languages.
  final Set<String> languages;

  const BehavioralRule({
    required this.id,
    required this.regex,
    required this.summary,
    this.highRisk = true,
    this.languages = const <String>{},
  });
}

final behavioralRules = <BehavioralRule>[
  BehavioralRule(
    id: 'empty_catch',
    // Matches `catch (_)` and `catch(_)` and `catch (_) { }` — Dart silent
    // catch is the single most common silent-fallback shape in this codebase.
    regex: RegExp(r'catch\s*\(\s*_\s*\)\s*\{?\s*\}?'),
    summary: 'Silent catch swallows runtime failures.',
    languages: <String>{'.dart'},
  ),
  BehavioralRule(
    id: 'guessed_now_timestamp',
    regex: RegExp(r'\?\?\s*DateTime\.now\(\)'),
    summary: 'Guessed current time used as metadata fallback.',
    languages: <String>{'.dart'},
  ),
  BehavioralRule(
    id: 'guessed_numeric_fallback',
    regex: RegExp(r'\?\?\s*1\.0\b|return\s+3\.5\b'),
    summary: 'Numeric fallback may hide missing required data.',
    languages: <String>{'.dart'},
  ),
  BehavioralRule(
    id: 'literal_null_coalesce',
    // Catches the common silent-fallback shape: `expr ?? null|0|false|''|""`.
    // These reduce a Result-bearing expression to a fixed value with no log.
    regex: RegExp("\\?\\?\\s*(null|0|false|''|\"\")"),
    summary: 'Null-coalesce to literal value hides upstream None/null.',
    languages: <String>{'.dart'},
  ),
  BehavioralRule(
    id: 'unwrap_or_literal',
    regex: RegExp(r'unwrap_or\((?:-?\d+(?:\.\d+)?|true|false)\)'),
    summary: 'Literal unwrap_or may silently coerce unknown state.',
    languages: <String>{'.rs'},
  ),
  BehavioralRule(
    id: 'unwrap_or_default',
    regex: RegExp(r'\.unwrap_or_default\(\)'),
    summary:
        'unwrap_or_default coerces error/None to type default with no signal.',
    languages: <String>{'.rs'},
  ),
  BehavioralRule(
    id: 'rust_drop_result',
    // `.ok();` discards a Result without logging or propagating the error.
    regex: RegExp(r'\.ok\(\)\s*;'),
    summary: 'Result dropped via .ok() — error path silently lost.',
    languages: <String>{'.rs'},
  ),
  BehavioralRule(
    id: 'rust_let_underscore',
    // `let _ = expr;` discards return value (commonly a Result) silently.
    regex: RegExp(r'let\s+_\s*='),
    summary: 'let _ = ... discards return value (often a Result).',
    languages: <String>{'.rs'},
  ),
  BehavioralRule(
    id: 'rust_if_let_err_underscore',
    // `if let Err(_) = expr` matches and ignores the actual error contents.
    regex: RegExp(r'if\s+let\s+Err\s*\(\s*_\s*\)\s*='),
    summary: 'if let Err(_) discards the error value.',
    languages: <String>{'.rs'},
  ),
  BehavioralRule(
    id: 'hardcoded_location_fallback',
    regex: RegExp(r'45\.0,\s*-75\.0'),
    summary: 'Hardcoded observer location fallback.',
  ),
  BehavioralRule(
    id: 'nonconvergence_best_guess',
    regex: RegExp(r'best guess|may not be optimal', caseSensitive: false),
    summary: 'Non-convergence treated as success.',
  ),
  BehavioralRule(
    id: 'simulated_runtime_path',
    regex: RegExp(
      r'NullDeviceOps|simulated devices|useSimulationMode|sequencerSetSimulationMode',
    ),
    summary: 'Simulation path present in runtime code.',
    highRisk: false,
  ),
  BehavioralRule(
    id: 'unimplemented_behavior',
    regex: RegExp(r'not yet implemented|not implemented', caseSensitive: false),
    summary: 'Runtime behavior not implemented.',
  ),
  BehavioralRule(
    id: 'comment_best_effort',
    // Comment patterns indicating known-incomplete behavior. These are how
    // engineers self-document silent fallbacks; we surface them as findings
    // so the register tracks them explicitly rather than living in code.
    regex: RegExp(
      r'//\s*(best[- ]effort|silently ignore|for now we just|temporary|hack|placeholder)',
      caseSensitive: false,
    ),
    summary: 'Comment marks known-incomplete or best-effort behavior.',
  ),
];

class BehavioralScan {
  final List<String> files;
  final List<Finding> findings;
  final Set<Finding> highRisk;

  const BehavioralScan(this.files, this.findings, this.highRisk);
}

/// Applies every rule to every runtime `.dart` / `.rs` file under [scope].
BehavioralScan scanBehavioral(AuditScope scope) {
  final files = <String>[];
  final findings = <Finding>[];
  final highRisk = <Finding>{};
  for (final path in scope.runtimeFiles(extensions: const {'.dart', '.rs'})) {
    final file = File(path);
    if (file.statSync().size > 2 * 1024 * 1024) {
      continue;
    }
    files.add(path);
    final ext = extensionOf(path);
    final lines = readLinesLenient(file);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      String? enclosing;
      for (final rule in behavioralRules) {
        if (rule.languages.isNotEmpty && !rule.languages.contains(ext)) {
          continue;
        }
        if (!rule.regex.hasMatch(line)) {
          continue;
        }
        final finding = Finding(
          rule: rule.id,
          scope: enclosing ??= enclosingScope(lines, i, ext),
          text: normalizeText(line),
          path: path,
          line: i + 1,
        );
        findings.add(finding);
        if (rule.highRisk) {
          highRisk.add(finding);
        }
      }
    }
  }
  return BehavioralScan(files, findings, highRisk);
}

List<String> readLinesLenient(File file) {
  try {
    return const LineSplitter().convert(file.readAsStringSync());
  } on FileSystemException {
    try {
      return const LineSplitter().convert(
        utf8.decode(file.readAsBytesSync(), allowMalformed: true),
      );
    } on FileSystemException {
      return const <String>[];
    }
  }
}
