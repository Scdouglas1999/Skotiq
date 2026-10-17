import 'dart:convert';
import 'dart:io';

/// Self-test for tools/production/bridge_boundary_audit.dart.
///
/// Builds synthetic workspaces in a temp dir and asserts the audit:
///  - exempts skotiq_core / skotiq_bridge,
///  - flags an un-whitelisted importer as a violation,
///  - honours the whitelist,
///  - extracts `show` and prefixed (`as`) symbols.
Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/bridge_boundary_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Bridge boundary audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_bridge_boundary_audit_self_test_',
  );
  try {
    // --- Passing fixture: only allowed packages import the bridge. ---
    await _writeFile(
      temp,
      'packages/skotiq_core/lib/src/backend/ffi_backend.dart',
      "import 'package:skotiq_bridge/skotiq_bridge.dart';\n",
    );
    await _writeFile(
      temp,
      'packages/skotiq_bridge/lib/skotiq_bridge.dart',
      'class NativeBridge {}\n',
    );
    // A bridge-importing app/test file that must be ignored (under test/).
    await _writeFile(
      temp,
      'apps/desktop/test/some_test.dart',
      "import 'package:skotiq_bridge/skotiq_bridge.dart';\n",
    );

    await _runAudit(script, temp);
    var report = _readJson(temp);
    _expect(report['passed'] == true, 'allowed-only fixture should pass');
    _expect(
      report['violationCount'] == 0,
      'allowed-only fixture should have no violations',
    );
    _expect(
      report['importerCount'] == 0,
      'core/bridge/test importers must be exempt from the importer list',
    );

    // --- Failing fixture: a UI file imports the bridge, not whitelisted. ---
    await _writeFile(
      temp,
      'packages/skotiq_app/lib/screens/stack_result/stack_result_screen.dart',
      "import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;\n"
          'void build() { bridge.apiAutoStretchImage(); }\n',
    );
    // A UI file using `show` for a single data type.
    await _writeFile(
      temp,
      'packages/skotiq_app/lib/widgets/guide_health_card.dart',
      "import 'package:skotiq_bridge/skotiq_bridge.dart' show Phd2State;\n"
          'Phd2State? state;\n',
    );

    final failing = await _runAudit(script, temp, allowFailure: true);
    _expect(failing.exitCode == 1, 'un-whitelisted importer should fail');
    report = _readJson(temp);
    _expect(report['passed'] == false, 'failing report should not pass');
    _expect(report['violationCount'] == 2, 'should report two violations');
    final violations = (report['violations'] as List).cast<Map>();
    final byFile = {for (final v in violations) v['file'] as String: v};
    _expect(
      byFile.containsKey(
        'packages/skotiq_app/lib/screens/stack_result/stack_result_screen.dart',
      ),
      'stack_result_screen should be a violation',
    );
    final stackSymbols =
        (byFile['packages/skotiq_app/lib/screens/stack_result/stack_result_screen.dart']!['symbols']
                as List)
            .cast<String>();
    _expect(
      stackSymbols.contains('bridge.apiAutoStretchImage'),
      'prefixed function symbol should be extracted, got $stackSymbols',
    );
    final guideSymbols =
        (byFile['packages/skotiq_app/lib/widgets/guide_health_card.dart']!['symbols']
                as List)
            .cast<String>();
    _expect(
      guideSymbols.contains('Phd2State'),
      'show symbol should be extracted, got $guideSymbols',
    );

    // --- Whitelist honoured: add guide_health_card to the whitelist. ---
    await _writeFile(temp, 'wl.json', '''
{
  "allow": [
    {
      "file": "packages/skotiq_app/lib/widgets/guide_health_card.dart",
      "reason": "thin UI data type"
    }
  ]
}
''');
    final withWhitelist = await _runAudit(
      script,
      temp,
      allowFailure: true,
      extraArgs: ['--whitelist', 'wl.json'],
    );
    // stack_result still violates, so exit is still 1.
    _expect(
      withWhitelist.exitCode == 1,
      'remaining un-whitelisted importer should still fail',
    );
    report = _readJson(temp);
    _expect(
      report['violationCount'] == 1,
      'whitelisted file should drop out of violations',
    );
    _expect(
      report['whitelistedCount'] == 1,
      'whitelisted file should be counted as an exception',
    );

    stdout.writeln('Bridge boundary audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root, {
  bool allowFailure = false,
  List<String> extraArgs = const [],
}) async {
  final result = await Process.run(
    'dart',
    [script.path, '--root', root.path, ...extraArgs],
    workingDirectory: root.path,
    runInShell: Platform.isWindows,
  );
  if (!allowFailure && result.exitCode != 0) {
    throw StateError(
      '${script.path} failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  return result;
}

Future<void> _writeFile(
  Directory root,
  String relativePath,
  String content,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

Map<String, dynamic> _readJson(Directory root) {
  final file = File(
    '${root.path}/docs/production-readiness/bridge-boundary.json',
  );
  if (!file.existsSync()) {
    throw StateError('Expected report was not written: ${file.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
