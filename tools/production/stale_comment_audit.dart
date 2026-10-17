// Stale-comment audit.
//
// Flags doc/line comments that assert a symbol is "unused at runtime",
// "not wired", "not registered", or that a conversion "will" happen in a
// "follow-up step" / "until that conversion lands" — when the current code
// CONTRADICTS that claim (the thing is, in fact, used at runtime).
//
// The motivating case: `apps/desktop/lib/headless_api/routes/headless_route.dart`
// carries a header comment claiming the headless server "currently still
// registers HTTP routes inline" and that `HeadlessRoute` is "unused at
// runtime ... until that conversion lands". But
// `apps/desktop/lib/headless_api_server/server_lifecycle.dart` builds a
// `List<HeadlessRoute>` from ~48 `buildXxxRoutes(...)` calls and feeds it to
// `registerRoutes(router, allRoutes)` at runtime. The comment is stale.
//
// This tool is intentionally narrow and evidence-based: it pairs a "claim"
// phrase with a "contradiction" probe (a symbol that, if found being invoked
// elsewhere, proves the claim false). A whitelist suppresses genuine,
// still-true placeholders (e.g. the deliberately-unimplemented S3SyncTarget).
//
// Read-only. Run: `dart run tools/production/stale_comment_audit.dart`.

import 'dart:convert';
import 'dart:io';

/// One stale-comment finding.
class StaleFinding {
  final String file;
  final int line;
  final String currentComment;
  final String correctedComment;
  final String evidence;

  const StaleFinding({
    required this.file,
    required this.line,
    required this.currentComment,
    required this.correctedComment,
    required this.evidence,
  });

  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'currentComment': currentComment,
    'correctedComment': correctedComment,
    'evidence': evidence,
  };
}

/// A declarative rule: when [claimRegex] matches a comment line in [file],
/// confirm the claim is stale by checking that [contradictionSymbol] IS
/// invoked at runtime in [contradictionFile]. If the contradiction is
/// present, the comment is stale and a finding is emitted.
class StaleRule {
  final String file;
  final RegExp claimRegex;
  final String contradictionFile;
  final RegExp contradictionRegex;
  final String correctedComment;

  const StaleRule({
    required this.file,
    required this.claimRegex,
    required this.contradictionFile,
    required this.contradictionRegex,
    required this.correctedComment,
  });
}

final List<StaleRule> _rules = [
  // The HeadlessRoute "unused at runtime / until that conversion lands" claim.
  StaleRule(
    file: 'apps/desktop/lib/headless_api/routes/headless_route.dart',
    claimRegex: RegExp(
      r'unused at runtime|until that conversion lands|'
      r'currently still registers HTTP routes inline|'
      r'a follow-up step will build on|in review and ready to consume',
    ),
    contradictionFile:
        'apps/desktop/lib/headless_api_server/server_lifecycle.dart',
    contradictionRegex: RegExp(r'registerRoutes\(\s*router'),
    correctedComment:
        'The conversion has landed. HeadlessApiServer.start() (see '
        'headless_api_server/server_lifecycle.dart) builds a '
        'List<HeadlessRoute> from the per-domain buildXxxRoutes(...) functions '
        'and feeds it to registerRoutes(router, allRoutes) at runtime. '
        'HeadlessRoute is the live route-table representation, not a '
        'checked-in-but-dormant type.',
  ),
];

/// Comments that LOOK suspicious but are confirmed still-true placeholders.
/// Each entry suppresses a known-good comment so the audit stays signal-only.
const Set<String> _whitelistKeys = {
  // S3SyncTarget really is unimplemented on purpose (SigV4 not hand-rolled).
  'packages/skotiq_core/lib/src/services/sync/sync_target.dart::S3',
  // OTA routes really are conditionally registered only when a controller
  // is wired; the "NOT registered here" comment is accurate.
  'apps/desktop/lib/headless_api/routes/update_routes.dart::update',
};

Future<void> main(List<String> args) async {
  final root = Directory(_argValue(args, '--root') ?? Directory.current.path);
  final findings = <StaleFinding>[];

  for (final rule in _rules) {
    final claimFile = File('${root.path}/${rule.file}');
    final contradictionFile = File('${root.path}/${rule.contradictionFile}');
    if (!claimFile.existsSync() || !contradictionFile.existsSync()) {
      continue;
    }

    final contradicts = rule.contradictionRegex.hasMatch(
      contradictionFile.readAsStringSync(),
    );
    if (!contradicts) {
      // The claim is NOT contradicted by current code -> not stale.
      continue;
    }

    final lines = claimFile.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!_isComment(line)) continue;
      if (!rule.claimRegex.hasMatch(line)) continue;
      findings.add(
        StaleFinding(
          file: rule.file,
          line: i + 1,
          currentComment: line.trim(),
          correctedComment: rule.correctedComment,
          evidence:
              '${rule.contradictionFile} contains a live call matching '
              '/${rule.contradictionRegex.pattern}/, proving the claim is stale.',
        ),
      );
    }
  }

  final emitJson = args.contains('--json');
  if (emitJson) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'whitelistedKeys': _whitelistKeys.toList()..sort(),
        'findings': findings.map((f) => f.toJson()).toList(),
      }),
    );
  } else {
    if (findings.isEmpty) {
      stdout.writeln('stale-comment-audit: no stale comments found.');
    } else {
      stdout.writeln('stale-comment-audit: ${findings.length} finding(s):');
      for (final f in findings) {
        stdout.writeln('  ${f.file}:${f.line}');
        stdout.writeln('    claim:     ${f.currentComment}');
        stdout.writeln('    corrected: ${f.correctedComment}');
        stdout.writeln('    evidence:  ${f.evidence}');
      }
    }
  }

  // Exit non-zero only when --fail-on-stale is passed, so the tool can be a
  // soft informational check by default and a CI gate when desired.
  if (findings.isNotEmpty && args.contains('--fail-on-stale')) {
    exitCode = 1;
  }
}

bool _isComment(String line) {
  final t = line.trimLeft();
  return t.startsWith('///') || t.startsWith('//') || t.startsWith('*');
}

String? _argValue(List<String> args, String flag) {
  final prefix = '$flag=';
  for (final a in args) {
    if (a.startsWith(prefix)) return a.substring(prefix.length);
    if (a == flag) {
      final i = args.indexOf(a);
      if (i + 1 < args.length) return args[i + 1];
    }
  }
  return null;
}
