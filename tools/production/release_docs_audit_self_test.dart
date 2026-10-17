import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/release_docs_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Release docs audit script not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_release_docs_audit_self_test_',
  );
  try {
    await _writeCompleteFixture(temp);
    final jsonPath =
        '${temp.path}/docs/production-readiness/release-docs-audit.json';
    final markdownPath =
        '${temp.path}/docs/production-readiness/release-docs-audit.md';

    final passing = await _run(script, temp, jsonPath, markdownPath);
    _expect(passing.exitCode == 0, 'complete fixture should pass');
    var report =
        jsonDecode(File(jsonPath).readAsStringSync()) as Map<String, dynamic>;
    _expect(report['passed'] == true, 'complete report should pass');
    _expect(report['issueCount'] == 0, 'complete report should have no issues');
    _expect(report['documentCount'] == 6, 'should audit 6 required docs');

    await File(
      '${temp.path}/docs/troubleshooting/firewall.md',
    ).writeAsString('# Firewall\n');
    final failing = await _run(script, temp, jsonPath, markdownPath);
    _expect(failing.exitCode != 0, 'incomplete fixture should fail');
    report =
        jsonDecode(File(jsonPath).readAsStringSync()) as Map<String, dynamic>;
    _expect(report['passed'] == false, 'incomplete report should fail');
    _expect(
      (report['issues'] as List).any(
        (issue) => issue.toString().contains('firewall.md'),
      ),
      'incomplete report should name the deficient doc',
    );

    stdout.writeln('Release docs audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<ProcessResult> _run(
  File script,
  Directory fixture,
  String jsonPath,
  String markdownPath,
) {
  return Process.run(
    'dart',
    [
      script.path,
      '--root',
      fixture.path,
      '--json-out',
      jsonPath,
      '--md-out',
      markdownPath,
    ],
    workingDirectory: Directory.current.path,
    runInShell: Platform.isWindows,
  );
}

Future<void> _writeCompleteFixture(Directory root) async {
  await _writeDoc(root, 'docs/release-notes-template.md', '''
# Skotiq Release Notes Template
## Release
## Supported Platforms
docs/supported-hardware-by-platform.md
docs/production-readiness/feature-parity-matrix.md
docs/production-readiness/public-release-external-evidence.json
docs/production-readiness/linux-release-build-evidence.json
docs/production-readiness/linux-release-ci-recipe.md
docs/production-readiness/linux-release-package-metadata.json
docs/production-readiness/full-hardware-control-smoke-evidence.json
docs/production-readiness/second-device-lan-firewall-smoke-evidence.json
docs/production-readiness/real-remote-control-actions-evidence.json
docs/production-readiness/final-release-signoff-evidence.json
runtimeSmokeChecks
/api/info.platformCapabilities
## Supported Hardware And Drivers
## Security And Remote Access
## Migration And Compatibility
## Known Limitations
## Verification Summary
''');
  await _writeDoc(root, 'docs/known-limitations.md', '''
# Known Limitations
## Acceptance Rules
unsupported controls are disabled or fail with an explicit reason
## Current Release Candidate Limitations
ASCOM COM is Windows-only
INDI weather and switch parity
docs/supported-hardware-by-platform.md
## Unsupported By Platform
## Release Notes Checklist
''');
  await _writeDoc(root, 'docs/supported-hardware-by-platform.md', '''
# Supported Hardware By Platform
/api/info.platformCapabilities
## Driver Backend Availability
ASCOM COM | Available | Unsupported | Unsupported
ASCOM Alpaca | Available | Available | Available
INDI | Available | Available | Available
## Device Category Coverage
## Native SDK Notes
## Release Verification Gate
''');
  await _writeDoc(root, 'docs/getting-started/installation.md', '''
# Installation
Windows
Linux
macOS
docs/release-notes-template.md
docs/supported-hardware-by-platform.md
docs/known-limitations.md
docs/production-readiness/linux-release-ci-recipe.md
docs/production-readiness/linux-release-package-metadata.json
runtimeSmokeChecks
''');
  await _writeDoc(root, 'docs/troubleshooting/firewall.md', '''
# Firewall
headless
LAN
token
firewall
docs/headless-secure-setup.md
second physical device
Windows Defender Firewall
server LAN URL
client IP
authenticated and unauthenticated responses
WebSocket reconnect
''');
  await _writeDoc(root, 'docs/migration-backup-restore.md', '''
# Migration Backup Restore
backup
restore
migration
older profile
docs/production-readiness/manual-migration-probe.md
docs/known-limitations.md
''');
}

Future<void> _writeDoc(
  Directory root,
  String relativePath,
  String contents,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
