import 'dart:convert';
import 'dart:io';

/// Self-test for tools/production/version_consistency_audit.dart.
///
/// Exercises the gate against temporary fixtures: it must pass when the three
/// version sources (version.yaml, desktop pubspec, mobile pubspec) and the OTA
/// builder all agree, and fail closed (exit 1) when versions disagree, when
/// build numbers disagree, or when the OTA builder stops sourcing its version
/// from version.yaml.
Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/version_consistency_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Version consistency audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_version_consistency_audit_self_test_',
  );
  try {
    // --- Aligned: all three sources + OTA builder agree on 5.0.0 / build 23.
    await _writeFixture(
      temp,
      versionYamlVersion: '5.0.0',
      versionYamlBuild: 23,
      desktopVersion: '5.0.0+23',
      mobileVersion: '5.0.0+23',
      otaReadsVersionYaml: true,
    );
    final aligned = await _runAudit(temp, jsonOut: 'report.json');
    _expect(
      aligned.exitCode == 0,
      'aligned fixture should pass (exit 0), got ${aligned.exitCode}\n'
      '${aligned.stdout}\n${aligned.stderr}',
    );
    final alignedReport = _readJson(temp, 'report.json');
    _expect(alignedReport['passed'] == true, 'aligned report should pass');
    _expect(
      alignedReport['issueCount'] == 0,
      'aligned report should have no issues',
    );
    _expect(
      (alignedReport['distinctVersions'] as List).length == 1,
      'aligned report should collapse to a single distinct version',
    );

    // --- Version-string disagreement: mobile lags behind.
    await _writeFixture(
      temp,
      versionYamlVersion: '5.0.0',
      versionYamlBuild: 23,
      desktopVersion: '5.0.0+23',
      mobileVersion: '4.3.0+22',
      otaReadsVersionYaml: true,
    );
    final versionMismatch = await _runAudit(
      temp,
      jsonOut: 'report.json',
      allowFailure: true,
    );
    _expect(
      versionMismatch.exitCode == 1,
      'version mismatch should fail (exit 1), got ${versionMismatch.exitCode}',
    );
    final versionReport = _readJson(temp, 'report.json');
    _expect(versionReport['passed'] == false, 'mismatch report should fail');
    _expect(
      (versionReport['issues'] as List)
          .join('\n')
          .contains('Version strings disagree'),
      'mismatch report should surface the version-disagreement issue',
    );

    // --- Build-number disagreement (versions match, builds differ).
    await _writeFixture(
      temp,
      versionYamlVersion: '5.0.0',
      versionYamlBuild: 21,
      desktopVersion: '5.0.0+23',
      mobileVersion: '5.0.0+22',
      otaReadsVersionYaml: true,
    );
    final buildMismatch = await _runAudit(
      temp,
      jsonOut: 'report.json',
      allowFailure: true,
    );
    _expect(
      buildMismatch.exitCode == 1,
      'build-number mismatch should fail (exit 1), got ${buildMismatch.exitCode}',
    );
    final buildReport = _readJson(temp, 'report.json');
    _expect(
      (buildReport['issues'] as List)
          .join('\n')
          .contains('Build numbers disagree'),
      'build mismatch report should surface the build-disagreement issue',
    );

    // --- OTA builder no longer derives its version from version.yaml.
    await _writeFixture(
      temp,
      versionYamlVersion: '5.0.0',
      versionYamlBuild: 23,
      desktopVersion: '5.0.0+23',
      mobileVersion: '5.0.0+23',
      otaReadsVersionYaml: false,
    );
    final otaDrift = await _runAudit(
      temp,
      jsonOut: 'report.json',
      allowFailure: true,
    );
    _expect(
      otaDrift.exitCode == 1,
      'OTA version-source drift should fail (exit 1), got ${otaDrift.exitCode}',
    );
    final otaReport = _readJson(temp, 'report.json');
    _expect(
      (otaReport['issues'] as List)
          .join('\n')
          .contains('no longer derives its version from version.yaml'),
      'OTA drift report should surface the version-source issue',
    );

    stdout.writeln('Version consistency audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writeFixture(
  Directory root, {
  required String versionYamlVersion,
  required int versionYamlBuild,
  required String desktopVersion,
  required String mobileVersion,
  required bool otaReadsVersionYaml,
}) async {
  await _writeFile(root, 'version.yaml', '''
version: "$versionYamlVersion"
build_number: $versionYamlBuild
channel: "stable"
min_update_version: "2.0.0"
''');
  await _writeFile(root, 'apps/desktop/pubspec.yaml', '''
name: skotiq_desktop
publish_to: 'none'
version: $desktopVersion

environment:
  sdk: ">=3.8.0 <4.0.0"
''');
  await _writeFile(root, 'apps/mobile/pubspec.yaml', '''
name: skotiq_mobile
publish_to: 'none'
version: $mobileVersion

environment:
  sdk: ">=3.8.0 <4.0.0"
''');
  // Minimal OTA builder: either it reads version.yaml's `version:` field
  // (the production behavior) or it hardcodes a version (the drift case).
  final otaBody = otaReadsVersionYaml
      ? r'''
    $versionYaml = Get-Content "version.yaml" -Raw
    $version = [regex]::Match($versionYaml, 'version:\s*"?([^"\s]+)"?').Groups[1].Value
'''
      : r'''
    $version = "9.9.9"
''';
  await _writeFile(root, 'scripts/build_update_package.ps1', otaBody);
}

Future<ProcessResult> _runAudit(
  Directory root, {
  String? jsonOut,
  bool allowFailure = false,
}) async {
  final script =
      '${Directory.current.path}/tools/production/version_consistency_audit.dart';
  final result = await Process.run(
    'dart',
    [
      script,
      '--root',
      root.path,
      if (jsonOut != null) ...['--json-out', jsonOut],
    ],
    workingDirectory: root.path,
    runInShell: Platform.isWindows,
  );
  if (!allowFailure && result.exitCode != 0) {
    throw StateError(
      '$script failed with exit ${result.exitCode}\n'
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

Map<String, dynamic> _readJson(Directory root, String relativePath) {
  final file = File('${root.path}/$relativePath');
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
