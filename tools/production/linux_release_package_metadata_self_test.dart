import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/linux_release_package_metadata.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Linux package metadata script not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_linux_release_package_metadata_self_test_',
  );
  try {
    final bundle = Directory('${temp.path}/bundle');
    await bundle.create(recursive: true);
    await File('${bundle.path}/skotiq').writeAsString('binary fixture\n');
    await File(
      '${bundle.path}/data/flutter_assets/AssetManifest.json',
    ).create(recursive: true).then((file) => file.writeAsString('{}\n'));
    final smokeLog = File('${temp.path}/linux-runtime-smoke.log');
    await smokeLog.writeAsString('Linux runtime smoke passed\n');

    final metadataPath = '${temp.path}/metadata.json';
    final evidencePath = '${temp.path}/evidence.json';
    final result = await Process.run(
      'dart',
      [
        script.path,
        '--bundle-dir=${bundle.path}',
        '--output-dir=${temp.path}/out',
        '--artifact-name=fixture-linux.tar.gz',
        '--metadata-output=$metadataPath',
        '--evidence-output=$evidencePath',
        '--write-evidence',
        '--runtime-smoke-log=${smokeLog.path}',
        '--runtime-smoke-passed',
        '--native-library-note=fixture native library note',
        '--linux-permission-note=fixture udev dialout note',
      ],
      workingDirectory: temp.path,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      throw StateError(
        '${script.path} failed with exit ${result.exitCode}\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}',
      );
    }

    final metadata =
        jsonDecode(File(metadataPath).readAsStringSync())
            as Map<String, dynamic>;
    final evidence =
        jsonDecode(File(evidencePath).readAsStringSync())
            as Map<String, dynamic>;

    _expect(
      metadata['platform'] == 'linux',
      'metadata platform should be linux',
    );
    _expect(
      metadata['metadataSchemaVersion'] == 2,
      'metadata should record schema version',
    );
    final toolVersions =
        metadata['toolVersions'] as Map<String, dynamic>? ?? const {};
    _expect(
      toolVersions['operatingSystem'] != null &&
          toolVersions['dartVersion'] != null,
      'metadata should record tool and OS provenance',
    );
    _expect(metadata['fileCount'] == 2, 'metadata should list bundle files');
    final files = (metadata['files'] as List).cast<Map<String, dynamic>>();
    _expect(
      files.every((file) => file['sha256'].toString().length == 64),
      'metadata should record per-file sha256 hashes',
    );
    _expect(
      metadata['artifactSha256'].toString().length == 64,
      'metadata should record artifact sha256',
    );
    _expect(
      File(metadata['artifactSha256Path'] as String).existsSync(),
      'metadata should record artifact sha256 sidecar path',
    );
    _expect(
      metadata.containsKey('sourceGitHead'),
      'metadata should include source git head field',
    );
    _expect(
      (metadata['nativeLibraryNotes'] as List).contains(
        'fixture native library note',
      ),
      'metadata should record native library notes',
    );
    _expect(
      (metadata['linuxPermissionNotes'] as List).contains(
        'fixture udev dialout note',
      ),
      'metadata should record Linux permission notes',
    );
    _expect(
      File(metadata['artifactPath'] as String).existsSync(),
      'metadata artifact path should exist',
    );
    _expect(evidence['buildPassed'] == true, 'evidence build should pass');
    _expect(
      evidence['metadataSchemaVersion'] == 2,
      'evidence should record metadata schema version',
    );
    final evidenceToolVersions =
        evidence['toolVersions'] as Map<String, dynamic>? ?? const {};
    _expect(
      evidenceToolVersions['operatingSystem'] != null &&
          evidenceToolVersions['dartVersion'] != null,
      'evidence should record tool and OS provenance',
    );
    _expect(
      evidence['runtimeSmokePassed'] == true,
      'evidence runtime smoke should pass',
    );
    _expect(
      (evidence['nativeLibraryNotes'] as List).contains(
        'fixture native library note',
      ),
      'evidence should record native library notes',
    );
    _expect(
      (evidence['linuxPermissionNotes'] as List).contains(
        'fixture udev dialout note',
      ),
      'evidence should record Linux permission notes',
    );
    final runtimeSmokeChecks =
        (evidence['runtimeSmokeChecks'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
    _expect(
      runtimeSmokeChecks.length == 4,
      'evidence should include every required runtime smoke check',
    );
    _expect(
      runtimeSmokeChecks.map((check) => check['check']).toSet().containsAll([
        'headless_process_started',
        'api_info_ok',
        'openapi_ok',
        'dashboard_asset_ok',
      ]),
      'evidence should name all required runtime smoke checks',
    );
    _expect(
      runtimeSmokeChecks.every(
        (check) =>
            check['passed'] == true &&
            (check['evidence']?.toString().isNotEmpty ?? false),
      ),
      'evidence should mark every runtime smoke check passed with evidence',
    );
    _expect(
      evidence['packageSha256'] == metadata['artifactSha256'],
      'evidence package hash should match metadata',
    );
    _expect(
      File(
        evidence['packageSha256Path'] as String,
      ).readAsStringSync().contains(evidence['packageSha256'] as String),
      'evidence package hash sidecar should contain the package hash',
    );

    stdout.writeln('Linux release package metadata self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
