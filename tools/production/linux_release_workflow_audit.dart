import 'dart:convert';
import 'dart:io';

const _defaultJsonOutputPath =
    'docs/production-readiness/linux-release-workflow-audit.json';
const _defaultMarkdownOutputPath =
    'docs/production-readiness/linux-release-workflow-audit.md';

const _workflowPath = '.github/workflows/linux-release-build.yml';
const _metadataToolPath =
    'tools/production/linux_release_package_metadata.dart';
const _ciRecipePath = 'docs/production-readiness/linux-release-ci-recipe.md';

const _requiredWorkflowText = [
  'workflow_dispatch:',
  'pull_request:',
  'runs-on: ubuntu-22.04',
  'timeout-minutes: 45',
  'actions/checkout@v7',
  'subosito/flutter-action@v2',
  'dtolnay/rust-toolchain@stable',
  'Swatinem/rust-cache@v2',
  'sudo apt-get install -y',
  'dart run melos bootstrap',
  'dart run melos run build:desktop:linux --no-select',
  'dart run tools/production/linux_release_package_metadata.dart',
  '--bundle-dir=apps/desktop/build/linux/x64/release/bundle',
  '--output-dir=build/release-linux',
  '--metadata-output=docs/production-readiness/linux-release-package-metadata.json',
  'actions/upload-artifact@v7',
  'SKOTIQ-LICENSE.txt',
  'THIRD_PARTY_NOTICES.md',
  'LGPL-2.1.txt',
  'SOURCE-COMMIT.txt',
  'if-no-files-found: error',
  'retention-days: 14',
  'build/release-linux/*.tar.gz',
  'build/release-linux/*.sha256',
  'docs/production-readiness/linux-release-package-metadata.json',
];

const _requiredMetadataToolText = [
  'sha256',
  'sourceGitHead',
  'githubRunId',
  'githubRepository',
  'githubSha',
  'metadataSchemaVersion',
  'toolVersions',
  'artifactSha256Path',
  'packageSha256Path',
  'runtimeSmokeChecks',
  'nativeLibraryNotes',
  'linuxPermissionNotes',
  'native-library-note',
  'linux-permission-note',
  'headless_process_started',
  'api_info_ok',
  'openapi_ok',
  'dashboard_asset_ok',
  'operatingSystem',
  'dartVersion',
  'flutterVersion',
  'rustcVersion',
  "'sha256': sha256",
  'artifactName',
  'metadata-output',
  'bundle-dir',
  'output-dir',
  'tar.gz',
];

const _requiredCiRecipeText = [
  '.github/workflows/linux-release-build.yml',
  'workflow_dispatch',
  'build/release-linux/*.sha256',
  'metadataSchemaVersion',
  'toolVersions',
  'packageSha256Path',
  'docs/production-readiness/linux-release-package-metadata.json',
  'docs/production-readiness/linux-release-build-evidence.json',
  'dart run tools/production/linux_release_package_metadata.dart',
  '--runtime-smoke-passed',
  'runtimeSmokeChecks',
  'nativeLibraryNotes',
  'linuxPermissionNotes',
  'native-library-note',
  'linux-permission-note',
  'headless_process_started',
  'api_info_ok',
  'openapi_ok',
  'dashboard_asset_ok',
  'runtime smoke',
  'does not replace',
];

Future<void> main(List<String> args) async {
  final root = Directory(_argValue(args, '--root') ?? Directory.current.path);
  final jsonOut = _argValue(args, '--json-out') ?? _defaultJsonOutputPath;
  final markdownOut = _argValue(args, '--md-out') ?? _defaultMarkdownOutputPath;
  final failOnIssue = !args.contains('--no-fail-on-issue');

  final workflow = _auditFile(
    root: root,
    path: _workflowPath,
    requiredText: _requiredWorkflowText,
  );
  final metadataTool = _auditFile(
    root: root,
    path: _metadataToolPath,
    requiredText: _requiredMetadataToolText,
  );
  final ciRecipe = _auditFile(
    root: root,
    path: _ciRecipePath,
    requiredText: _requiredCiRecipeText,
  );
  final issues = [
    ...workflow.issues,
    ...metadataTool.issues,
    ...ciRecipe.issues,
  ];
  final passed = issues.isEmpty;
  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'issueCount': issues.length,
    'issues': issues,
    'workflow': workflow.toJson(),
    'metadataTool': metadataTool.toJson(),
    'ciRecipe': ciRecipe.toJson(),
    'metadataRequirements': {
      'packageSha256': true,
      'perFileSha256': true,
      'sourceGitHead': true,
      'githubRunContext': true,
      'schemaVersion': true,
      'toolVersions': true,
      'sha256Sidecar': true,
      'nativeLibraryNotes': true,
      'linuxPermissionNotes': true,
    },
    'workflowRequirements': {
      'checkout': true,
      'timeoutMinutes': true,
      'failOnMissingArtifacts': true,
      'artifactRetention': true,
    },
    'recipeRequirements': {
      'workflowDispatch': true,
      'sha256Sidecar': true,
      'schemaVersion': true,
      'toolVersions': true,
      'evidencePath': true,
      'runtimeSmokeGate': true,
      'structuredRuntimeSmokeChecks': true,
      'nativeLibraryNotes': true,
      'linuxPermissionNotes': true,
    },
    'policy':
        'Linux release automation must define a repeatable Ubuntu workflow and documented CI recipe that build the Linux desktop bundle, generate package hash/provenance metadata, upload package and metadata artifacts, and preserve the separate runtime smoke evidence gate. This audit does not prove the workflow has run successfully.',
  };

  await File(jsonOut).parent.create(recursive: true);
  await File(
    jsonOut,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(markdownOut).parent.create(recursive: true);
  await File(markdownOut).writeAsString(
    _renderMarkdown(
      passed: passed,
      issues: issues,
      workflow: workflow,
      metadataTool: metadataTool,
      ciRecipe: ciRecipe,
    ),
  );

  stdout.writeln('Linux release workflow audit complete.');
  stdout.writeln('Passed: $passed');
  stdout.writeln('Issues: ${issues.length}');
  stdout.writeln('JSON: $jsonOut');
  stdout.writeln('Markdown: $markdownOut');

  if (failOnIssue && !passed) {
    exit(1);
  }
}

_FileAudit _auditFile({
  required Directory root,
  required String path,
  required List<String> requiredText,
}) {
  final file = File('${root.path}/$path');
  if (!file.existsSync()) {
    return _FileAudit(
      path: path,
      exists: false,
      sizeBytes: 0,
      missingText: requiredText,
    );
  }
  final text = file.readAsStringSync();
  return _FileAudit(
    path: path,
    exists: true,
    sizeBytes: file.lengthSync(),
    missingText: [
      for (final required in requiredText)
        if (!text.contains(required)) required,
    ],
  );
}

String _renderMarkdown({
  required bool passed,
  required List<String> issues,
  required _FileAudit workflow,
  required _FileAudit metadataTool,
  required _FileAudit ciRecipe,
}) {
  final buffer = StringBuffer()
    ..writeln('# Linux Release Workflow Audit')
    ..writeln()
    ..writeln('- Passed: `$passed`')
    ..writeln('- Issues: `${issues.length}`')
    ..writeln()
    ..writeln(
      'This audit verifies repeatable Linux release automation exists. It does not replace a successful Linux workflow run or Linux runtime smoke evidence.',
    )
    ..writeln()
    ..writeln('## Files')
    ..writeln()
    ..writeln('| File | Exists | Missing required text |')
    ..writeln('| --- | --- | ---: |')
    ..writeln(
      '| `${workflow.path}` | `${workflow.exists}` | `${workflow.missingText.length}` |',
    )
    ..writeln(
      '| `${metadataTool.path}` | `${metadataTool.exists}` | `${metadataTool.missingText.length}` |',
    )
    ..writeln(
      '| `${ciRecipe.path}` | `${ciRecipe.exists}` | `${ciRecipe.missingText.length}` |',
    );

  if (issues.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Issues')
      ..writeln();
    for (final issue in issues) {
      buffer.writeln('- $issue');
    }
  }

  return buffer.toString();
}

String? _argValue(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == name && i + 1 < args.length) {
      return args[i + 1];
    }
    if (arg.startsWith('$name=')) {
      return arg.substring(name.length + 1);
    }
  }
  return null;
}

class _FileAudit {
  final String path;
  final bool exists;
  final int sizeBytes;
  final List<String> missingText;

  const _FileAudit({
    required this.path,
    required this.exists,
    required this.sizeBytes,
    required this.missingText,
  });

  List<String> get issues {
    if (!exists) {
      return ['Missing required file: $path'];
    }
    return [
      for (final text in missingText) '$path is missing required text: `$text`',
    ];
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'exists': exists,
    'sizeBytes': sizeBytes,
    'missingText': missingText,
    'missingTextCount': missingText.length,
    'passed': exists && missingText.isEmpty,
  };
}
