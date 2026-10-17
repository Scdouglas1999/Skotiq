import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/linux_release_workflow_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Linux release workflow audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_linux_release_workflow_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp);
    final passing = _readJson(
      temp,
      'docs/production-readiness/linux-release-workflow-audit.json',
    );
    _expect(passing['passed'] == true, 'passing fixture should pass');
    _expect(
      passing['issueCount'] == 0,
      'passing fixture should have no issues',
    );
    final metadataRequirements =
        passing['metadataRequirements'] as Map? ?? const {};
    _expect(
      metadataRequirements['perFileSha256'] == true &&
          metadataRequirements['sourceGitHead'] == true &&
          metadataRequirements['schemaVersion'] == true &&
          metadataRequirements['toolVersions'] == true &&
          metadataRequirements['sha256Sidecar'] == true &&
          metadataRequirements['nativeLibraryNotes'] == true &&
          metadataRequirements['linuxPermissionNotes'] == true,
      'passing fixture should report strengthened metadata requirements',
    );
    final workflowRequirements =
        passing['workflowRequirements'] as Map? ?? const {};
    _expect(
      workflowRequirements['checkout'] == true &&
          workflowRequirements['timeoutMinutes'] == true &&
          workflowRequirements['failOnMissingArtifacts'] == true &&
          workflowRequirements['artifactRetention'] == true,
      'passing fixture should report strengthened workflow requirements',
    );
    final recipeRequirements =
        passing['recipeRequirements'] as Map? ?? const {};
    _expect(
      recipeRequirements['workflowDispatch'] == true &&
          recipeRequirements['sha256Sidecar'] == true &&
          recipeRequirements['schemaVersion'] == true &&
          recipeRequirements['toolVersions'] == true &&
          recipeRequirements['evidencePath'] == true &&
          recipeRequirements['runtimeSmokeGate'] == true &&
          recipeRequirements['structuredRuntimeSmokeChecks'] == true &&
          recipeRequirements['nativeLibraryNotes'] == true &&
          recipeRequirements['linuxPermissionNotes'] == true,
      'passing fixture should report documented CI recipe requirements',
    );

    await _writeFailingFixture(temp);
    final failingResult = await _runAudit(script, temp, allowFailure: true);
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/linux-release-workflow-audit.json',
    );
    _expect(failing['passed'] == false, 'failing report should not pass');
    final issues = (failing['issues'] as List? ?? const []).join('\n');
    _expect(
      issues.contains('linux_release_package_metadata.dart'),
      'failing report should mention missing metadata tooling',
    );
    _expect(
      issues.contains('linux-release-ci-recipe.md'),
      'failing report should mention missing CI recipe coverage',
    );

    stdout.writeln('Linux release workflow audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await File('${root.path}/.github/workflows/linux-release-build.yml')
      .create(recursive: true)
      .then(
        (file) => file.writeAsString('''
name: Linux Release Build
on:
  workflow_dispatch:
  pull_request:
jobs:
  linux-release-build:
    runs-on: ubuntu-22.04
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v7
      - uses: subosito/flutter-action@v2
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
      - run: sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev tar
      - run: dart run melos bootstrap
      - run: dart run melos run build:desktop:linux --no-select
      - run: |
          cp LICENSE apps/desktop/build/linux/x64/release/bundle/SKOTIQ-LICENSE.txt
          cp docs/THIRD_PARTY_NOTICES.md apps/desktop/build/linux/x64/release/bundle/THIRD_PARTY_NOTICES.md
          cp third_party/licenses/LGPL-2.1.txt apps/desktop/build/linux/x64/release/bundle/LGPL-2.1.txt
          printf '%s\\n' "\$GITHUB_SHA" > apps/desktop/build/linux/x64/release/bundle/SOURCE-COMMIT.txt
      - run: |
          dart run tools/production/linux_release_package_metadata.dart \\
            --bundle-dir=apps/desktop/build/linux/x64/release/bundle \\
            --output-dir=build/release-linux \\
            --metadata-output=docs/production-readiness/linux-release-package-metadata.json
      - uses: actions/upload-artifact@v7
        with:
          path: |
            build/release-linux/*.tar.gz
            build/release-linux/*.sha256
          if-no-files-found: error
          retention-days: 14
      - uses: actions/upload-artifact@v7
        with:
          path: docs/production-readiness/linux-release-package-metadata.json
          if-no-files-found: error
          retention-days: 14
'''),
      );
  await File(
        '${root.path}/tools/production/linux_release_package_metadata.dart',
      )
      .create(recursive: true)
      .then(
        (file) => file.writeAsString(
          "const words = \"sha256 sourceGitHead githubRunId githubRepository githubSha metadataSchemaVersion toolVersions artifactSha256Path packageSha256Path runtimeSmokeChecks nativeLibraryNotes linuxPermissionNotes native-library-note linux-permission-note headless_process_started api_info_ok openapi_ok dashboard_asset_ok operatingSystem dartVersion flutterVersion rustcVersion artifactName metadata-output bundle-dir output-dir tar.gz\"; const map = {'sha256': sha256};",
        ),
      );
  await File(
        '${root.path}/docs/production-readiness/linux-release-ci-recipe.md',
      )
      .create(recursive: true)
      .then(
        (file) => file.writeAsString('''
.github/workflows/linux-release-build.yml
workflow_dispatch
build/release-linux/*.sha256
metadataSchemaVersion
toolVersions
packageSha256Path
docs/production-readiness/linux-release-package-metadata.json
docs/production-readiness/linux-release-build-evidence.json
dart run tools/production/linux_release_package_metadata.dart
--runtime-smoke-passed
runtimeSmokeChecks
nativeLibraryNotes
linuxPermissionNotes
native-library-note
linux-permission-note
headless_process_started
api_info_ok
openapi_ok
dashboard_asset_ok
runtime smoke
does not replace
'''),
      );
}

Future<void> _writeFailingFixture(Directory root) async {
  await File(
    '${root.path}/.github/workflows/linux-release-build.yml',
  ).writeAsString('name: broken\n');
  final metadata = File(
    '${root.path}/tools/production/linux_release_package_metadata.dart',
  );
  if (metadata.existsSync()) {
    await metadata.delete();
  }
  final recipe = File(
    '${root.path}/docs/production-readiness/linux-release-ci-recipe.md',
  );
  if (recipe.existsSync()) {
    await recipe.delete();
  }
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [script.path, '--root', root.path],
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
