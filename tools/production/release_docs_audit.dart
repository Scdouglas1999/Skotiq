import 'dart:convert';
import 'dart:io';

const _jsonOutputPath = 'docs/production-readiness/release-docs-audit.json';
const _markdownOutputPath = 'docs/production-readiness/release-docs-audit.md';

const _requiredDocs = <_RequiredDoc>[
  _RequiredDoc(
    path: 'docs/release-validation-template.md',
    label: 'Release validation template',
    requiredText: [
      '## Release',
      '## Supported Platforms',
      '## Supported Hardware And Drivers',
      '## Security And Remote Access',
      '## Migration And Compatibility',
      '## Known Limitations',
      '## Verification Summary',
      'docs/supported-hardware-by-platform.md',
      'docs/production-readiness/feature-parity-matrix.md',
      'docs/production-readiness/public-release-external-evidence.json',
      'docs/production-readiness/linux-release-build-evidence.json',
      'docs/production-readiness/linux-release-ci-recipe.md',
      'docs/production-readiness/linux-release-package-metadata.json',
      'docs/production-readiness/full-hardware-control-smoke-evidence.json',
      'docs/production-readiness/second-device-lan-firewall-smoke-evidence.json',
      'docs/production-readiness/real-remote-control-actions-evidence.json',
      'docs/production-readiness/final-release-signoff-evidence.json',
      'runtimeSmokeChecks',
      '/api/info.platformCapabilities',
    ],
  ),
  _RequiredDoc(
    path: 'docs/known-limitations.md',
    label: 'Known limitations',
    requiredText: [
      '## Acceptance Rules',
      '## Current Release Candidate Limitations',
      '## Unsupported By Platform',
      '## Release Notes Checklist',
      'unsupported controls are disabled or fail with an explicit reason',
      'ASCOM COM is Windows-only',
      'INDI weather and switch parity',
      'docs/supported-hardware-by-platform.md',
    ],
  ),
  _RequiredDoc(
    path: 'docs/supported-hardware-by-platform.md',
    label: 'Supported hardware by platform',
    requiredText: [
      '## Driver Backend Availability',
      '## Device Category Coverage',
      '## Native SDK Notes',
      '## Release Verification Gate',
      'ASCOM COM | Available | Unsupported | Unsupported',
      'ASCOM Alpaca | Available | Available | Available',
      'INDI | Available | Available | Available',
      '/api/info.platformCapabilities',
    ],
  ),
  _RequiredDoc(
    path: 'docs/getting-started/installation.md',
    label: 'Installation guide',
    requiredText: [
      'docs/release-validation-template.md',
      'docs/supported-hardware-by-platform.md',
      'docs/known-limitations.md',
      'docs/production-readiness/linux-release-ci-recipe.md',
      'docs/production-readiness/linux-release-package-metadata.json',
      'runtimeSmokeChecks',
      'Linux',
      'Windows',
      'macOS',
    ],
  ),
  _RequiredDoc(
    path: 'docs/troubleshooting/firewall.md',
    label: 'Firewall troubleshooting',
    requiredText: [
      'headless',
      'LAN',
      'token',
      'firewall',
      'docs/headless-secure-setup.md',
      'second physical device',
      'Windows Defender Firewall',
      'server LAN URL',
      'client IP',
      'authenticated and unauthenticated responses',
      'WebSocket reconnect',
    ],
  ),
  _RequiredDoc(
    path: 'docs/migration-backup-restore.md',
    label: 'Migration, backup, and restore',
    requiredText: [
      'backup',
      'restore',
      'migration',
      'older profile',
      'docs/production-readiness/manual-migration-probe.md',
      'docs/known-limitations.md',
    ],
  ),
];

Future<void> main(List<String> args) async {
  final root = Directory(_argValue(args, '--root') ?? Directory.current.path);
  final jsonOut = _argValue(args, '--json-out') ?? _jsonOutputPath;
  final markdownOut = _argValue(args, '--md-out') ?? _markdownOutputPath;
  final failOnIssue = !args.contains('--no-fail-on-issue');

  final docReports = <_DocReport>[];
  for (final doc in _requiredDocs) {
    docReports.add(_auditDoc(root, doc));
  }

  final issues = [for (final report in docReports) ...report.issues];
  final passed = issues.isEmpty;
  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'documentCount': docReports.length,
    'issueCount': issues.length,
    'issues': issues,
    'documents': docReports.map((doc) => doc.toJson()).toList(),
    'policy':
        'Release-critical docs must exist and include required release notes, platform support, known limitations, installation, firewall, and migration/backup sections or links.',
  };

  await File(jsonOut).parent.create(recursive: true);
  await File(
    jsonOut,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(markdownOut).parent.create(recursive: true);
  await File(markdownOut).writeAsString(
    _renderMarkdown(passed: passed, docReports: docReports, issues: issues),
  );

  stdout.writeln('Release docs audit complete.');
  stdout.writeln('Passed: $passed');
  stdout.writeln('Documents: ${docReports.length}');
  stdout.writeln('Issues: ${issues.length}');
  stdout.writeln('JSON: $jsonOut');
  stdout.writeln('Markdown: $markdownOut');

  if (failOnIssue && !passed) {
    exit(1);
  }
}

_DocReport _auditDoc(Directory root, _RequiredDoc doc) {
  final file = File('${root.path}/${doc.path}');
  if (!file.existsSync()) {
    return _DocReport(
      path: doc.path,
      label: doc.label,
      exists: false,
      missingText: doc.requiredText,
      sizeBytes: 0,
    );
  }

  final text = file.readAsStringSync();
  final missingText = doc.requiredText
      .where((required) => !text.contains(required))
      .toList(growable: false);

  return _DocReport(
    path: doc.path,
    label: doc.label,
    exists: true,
    missingText: missingText,
    sizeBytes: file.lengthSync(),
  );
}

String _renderMarkdown({
  required bool passed,
  required List<_DocReport> docReports,
  required List<String> issues,
}) {
  final buffer = StringBuffer()
    ..writeln('# Release Docs Audit')
    ..writeln()
    ..writeln('- Passed: `$passed`')
    ..writeln('- Documents: `${docReports.length}`')
    ..writeln('- Issues: `${issues.length}`')
    ..writeln()
    ..writeln(
      'This audit checks release-critical documentation for required sections and cross-links. It does not replace release-specific reviewer sign-off.',
    )
    ..writeln()
    ..writeln('## Documents')
    ..writeln()
    ..writeln('| Document | Exists | Missing required text |')
    ..writeln('| --- | --- | ---: |');

  for (final doc in docReports) {
    buffer.writeln(
      '| `${doc.path}` | `${doc.exists}` | `${doc.missingText.length}` |',
    );
  }

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

class _RequiredDoc {
  final String path;
  final String label;
  final List<String> requiredText;

  const _RequiredDoc({
    required this.path,
    required this.label,
    required this.requiredText,
  });
}

class _DocReport {
  final String path;
  final String label;
  final bool exists;
  final List<String> missingText;
  final int sizeBytes;

  const _DocReport({
    required this.path,
    required this.label,
    required this.exists,
    required this.missingText,
    required this.sizeBytes,
  });

  List<String> get issues {
    if (!exists) {
      return ['Missing required release doc: $path'];
    }
    return [
      for (final text in missingText) '$path is missing required text: `$text`',
    ];
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'label': label,
    'exists': exists,
    'sizeBytes': sizeBytes,
    'missingText': missingText,
    'missingTextCount': missingText.length,
    'passed': exists && missingText.isEmpty,
  };
}
