// Self-test for stale_comment_audit.dart.
//
// Validates two properties against synthetic fixtures written to a temp dir:
//   1. A claim that IS contradicted by current code is reported as stale.
//   2. A claim whose contradiction probe is NOT present (the code still
//      matches the comment) is NOT reported.
//
// The production tool's hard-coded rules point at real repo paths, so this
// self-test exercises the same detection logic by invoking the tool against a
// temp --root that mirrors only the two files a rule references. It does NOT
// require flutter/build and runs in milliseconds.
//
// Run: `dart run tools/production/stale_comment_audit_self_test.dart`.

import 'dart:io';

Future<void> main() async {
  final failures = <String>[];

  final selfPath = Platform.script.toFilePath();
  final toolPath = selfPath.replaceFirst(
    'stale_comment_audit_self_test.dart',
    'stale_comment_audit.dart',
  );
  if (!File(toolPath).existsSync()) {
    stderr.writeln('FAIL: cannot locate stale_comment_audit.dart at $toolPath');
    exitCode = 1;
    return;
  }

  // CASE 1: contradiction present -> expect a stale finding.
  {
    final root = await _makeRoot(
      claimBody:
          '/// HeadlessRoute is unused at runtime until that conversion lands.\n'
          'class HeadlessRoute {}\n',
      contradictionBody:
          'void start() {\n  registerRoutes( router, allRoutes);\n}\n',
    );
    final out = await _runTool(toolPath, root, fail: true);
    if (out.exitCode != 1) {
      failures.add(
        'CASE1: expected exit 1 (stale found w/ --fail-on-stale), '
        'got ${out.exitCode}',
      );
    }
    if (!out.stdout.contains('headless_route.dart:1')) {
      failures.add('CASE1: expected finding at headless_route.dart:1');
    }
    root.deleteSync(recursive: true);
  }

  // CASE 2: contradiction ABSENT (code still registers inline) -> no finding.
  {
    final root = await _makeRoot(
      claimBody:
          '/// HeadlessRoute is unused at runtime until that conversion lands.\n'
          'class HeadlessRoute {}\n',
      contradictionBody:
          'void start() {\n  router.get("/x", h);\n  router.post("/y", h);\n}\n',
    );
    final out = await _runTool(toolPath, root, fail: true);
    if (out.exitCode != 0) {
      failures.add(
        'CASE2: expected exit 0 (no stale finding), got ${out.exitCode}',
      );
    }
    if (!out.stdout.contains('no stale comments found')) {
      failures.add('CASE2: expected "no stale comments found"');
    }
    root.deleteSync(recursive: true);
  }

  if (failures.isEmpty) {
    stdout.writeln('stale-comment-audit self-test: PASS (2 cases)');
  } else {
    stdout.writeln('stale-comment-audit self-test: FAIL');
    for (final f in failures) {
      stdout.writeln('  - $f');
    }
    exitCode = 1;
  }
}

Future<Directory> _makeRoot({
  required String claimBody,
  required String contradictionBody,
}) async {
  final root = Directory.systemTemp.createTempSync('stale_audit_test_');
  final claimFile = File(
    '${root.path}/apps/desktop/lib/headless_api/routes/headless_route.dart',
  );
  claimFile.createSync(recursive: true);
  claimFile.writeAsStringSync(claimBody);

  final contradictionFile = File(
    '${root.path}/apps/desktop/lib/headless_api_server/server_lifecycle.dart',
  );
  contradictionFile.createSync(recursive: true);
  contradictionFile.writeAsStringSync(contradictionBody);
  return root;
}

Future<({int exitCode, String stdout})> _runTool(
  String toolPath,
  Directory root, {
  required bool fail,
}) async {
  final result = await Process.run('dart', [
    'run',
    toolPath,
    '--root=${root.path}',
    if (fail) '--fail-on-stale',
  ]);
  return (
    exitCode: result.exitCode,
    stdout: (result.stdout as String) + (result.stderr as String),
  );
}
