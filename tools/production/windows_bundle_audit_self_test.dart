import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/windows_bundle_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Windows bundle audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_windows_bundle_audit_self_test_',
  );
  try {
    final missingBundle = await _runAudit(
      script,
      temp,
      '${temp.path}/missing-bundle',
      allowFailure: true,
    );
    _expect(
      missingBundle.exitCode == 2,
      'missing bundle fixture should exit 2',
    );
    final missingBundleReport = _readJson(
      temp,
      'docs/production-readiness/windows-bundle-audit.json',
    );
    _expect(
      missingBundleReport['passed'] == false &&
          missingBundleReport['bundleExists'] == false,
      'missing bundle fixture should replace stale evidence with a failure report',
    );
    _expect(
      // No `+ 1`: the audit no longer carries a required glob prefix. It
      // required `FF`, which never shipped in any real bundle — the published,
      // working v6.0.0 Windows archive has no FF*/ffmpeg file either.
      missingBundleReport['missingRequiredFileCount'] == _requiredFiles.length,
      'missing bundle report should list every required artifact',
    );

    final passingBundle = Directory('${temp.path}/passing-bundle');
    await _writePassingBundle(passingBundle);
    await _runAudit(script, temp, passingBundle.path);
    final passing = _readJson(
      temp,
      'docs/production-readiness/windows-bundle-audit.json',
    );
    _expect(passing['passed'] == true, 'passing fixture should pass');
    _expect(
      passing['missingRequiredFileCount'] == 0,
      'passing fixture should have all required files',
    );
    _expect(
      passing['disallowedFileCount'] == 0,
      'passing fixture should have no disallowed files',
    );

    final failingBundle = Directory('${temp.path}/failing-bundle');
    await _writeFailingBundle(failingBundle);
    final failingResult = await _runAudit(
      script,
      temp,
      failingBundle.path,
      allowFailure: true,
    );
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/windows-bundle-audit.json',
    );
    _expect(failing['passed'] == false, 'failing report should not pass');
    final missing = failing['missingRequiredFiles'] as List? ?? const [];
    final disallowed = failing['disallowedFiles'] as List? ?? const [];
    _expect(
      missing.contains('sqlite3.dll') &&
          missing.contains('skotiq_bridge.dll (empty)'),
      'failing fixture should identify missing and empty required files',
    );
    _expect(
      disallowed.contains('skotiq.pdb') &&
          disallowed.contains('data/flutter_assets/test/fixture.txt'),
      'failing fixture should identify disallowed files and segments',
    );

    stdout.writeln('Windows bundle audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingBundle(Directory bundle) async {
  if (bundle.existsSync()) {
    await bundle.delete(recursive: true);
  }

  for (final path in _requiredFiles) {
    await _writeFile(bundle, path, 'fixture');
  }
}

Future<void> _writeFailingBundle(Directory bundle) async {
  await _writePassingBundle(bundle);
  await File('${bundle.path}/sqlite3.dll').delete();
  await File('${bundle.path}/skotiq_bridge.dll').writeAsString('');
  await _writeFile(bundle, 'skotiq.pdb', 'debug symbols');
  await _writeFile(
    bundle,
    'data/flutter_assets/test/fixture.txt',
    'test fixture',
  );
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root,
  String bundlePath, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [script.path, bundlePath],
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

const _requiredFiles = <String>[
  'skotiq.exe',
  'skotiq_bridge.dll',
  'flutter_windows.dll',
  'sqlite3.dll',
  'libraw.dll',
  'libwebrtc.dll',
  'data/app.so',
  'data/icudtl.dat',
  'data/flutter_assets/AssetManifest.bin',
  'data/flutter_assets/FontManifest.json',
  'data/flutter_assets/NativeAssetsManifest.json',
  'data/flutter_assets/web_dashboard/index.html',
  'data/flutter_assets/web_dashboard/css/dashboard.css',
  'data/flutter_assets/web_dashboard/js/api.js',
  'data/flutter_assets/web_dashboard/js/app.js',
];
