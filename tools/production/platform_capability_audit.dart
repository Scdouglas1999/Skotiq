import 'dart:convert';
import 'dart:io';

const _defaultJsonOutputPath =
    'docs/production-readiness/platform-capability-audit.json';
const _defaultMarkdownOutputPath =
    'docs/production-readiness/platform-capability-audit.md';

const _requiredFiles = <_RequiredFile>[
  _RequiredFile(
    path:
        'packages/skotiq_core/lib/src/models/backend/platform_capabilities.dart',
    label: 'Platform capability model',
    requiredText: [
      "backend: 'ascom'",
      "label: 'ASCOM COM'",
      'supportedPlatforms: [windows]',
      "backend: 'alpaca'",
      "backend: 'indi'",
      "backend: 'native'",
      "label: 'Native SDK'",
      "statusOverride: 'capability-gated'",
      "backend: 'simulator'",
      'PlatformCapabilityReport forPlatform',
      'Map<String, dynamic> toJson',
    ],
  ),
  _RequiredFile(
    path:
        'packages/skotiq_core/test/models/platform_capabilities_test.dart',
    label: 'Platform capability model tests',
    requiredText: [
      'marks ASCOM COM as Windows-only',
      'serializes deterministic unsupported reasons for API responses',
      'serializes capability-gated backends for API responses',
      'matches the public driver backend status matrix',
      'PlatformCapabilityMatrix.windows',
      'capability-gated',
    ],
  ),
  _RequiredFile(
    path: 'apps/desktop/lib/headless_api/handlers/system_handlers.dart',
    label: 'Headless capability API system handlers',
    requiredText: [
      // `forPlatform(...)` is dart-format line-wrapped here, so match the
      // capability-model call by its stable prefix rather than the inline
      // single-line form.
      'PlatformCapabilityMatrix.forPlatform(',
      "'platformCapabilities': platformCapabilities.toJson()",
      "'deviceDrivers': platformCapabilities.toJson()",
      "'platform': platformCapabilities.platform",
    ],
  ),
  _RequiredFile(
    path: 'apps/desktop/lib/headless_api/handlers/system_endpoint_catalog.dart',
    label: 'Headless endpoint catalog capability exposure',
    requiredText: [
      // The capability endpoints live in this hand-maintained catalog,
      // re-exported via availableHeadlessEndpoints through
      // system_handlers.dart, so the API-exposure invariant is pinned here.
      "'GET /api/equipment/camera/capabilities'",
      "'GET /api/equipment/mount/capabilities'",
      "'GET /api/equipment/focuser/capabilities'",
      "'GET /api/equipment/filter-wheel/capabilities'",
      "'GET /api/equipment/rotator/capabilities'",
    ],
  ),
  _RequiredFile(
    path: 'apps/desktop/lib/headless_api/handlers/equipment_handlers.dart',
    label: 'Equipment capability API handlers',
    requiredText: [
      'handleCameraCapabilities',
      'handleMountCapabilities',
      'handleFocuserCapabilities',
      'handleFilterWheelCapabilities',
      'handleRotatorCapabilities',
      'getCameraCapabilities(deviceId)',
      'getMountCapabilities(deviceId)',
      'getFocuserCapabilities(deviceId)',
      'getFilterWheelCapabilities(deviceId)',
      'getRotatorCapabilities(deviceId)',
      'return jsonOk(caps.toJson())',
      'Device not found or capabilities unavailable',
    ],
  ),
  _RequiredFile(
    path: 'apps/desktop/test/headless_api/equipment_handlers_test.dart',
    label: 'Equipment capability API handler tests',
    requiredText: [
      'capability backend failures return JSON internal server errors',
      'handleCameraCapabilities',
      'handleMountCapabilities',
      'handleFocuserCapabilities',
      'handleFilterWheelCapabilities',
      'handleRotatorCapabilities',
      'HttpStatus.internalServerError',
      "response.headers['content-type'], 'application/json'",
    ],
  ),
  _RequiredFile(
    path: 'apps/desktop/test/headless_api/auth_middleware_test.dart',
    label: 'Headless capability API tests',
    requiredText: [
      '_expectReleaseScopedDriverMatrix',
      "info.body['platformCapabilities']",
      "selfTest.body['deviceDrivers']",
      'containsAll([\'ascom\', \'alpaca\', \'indi\', \'native\', \'simulator\'])',
      'Windows COM drivers',
      "native['status'], 'capability-gated'",
      "simulator['status'], 'capability-gated'",
    ],
  ),
  _RequiredFile(
    path:
        'packages/skotiq_app/lib/screens/equipment/widgets/backend_selector_chips.dart',
    label: 'Backend selector platform gating',
    requiredText: [
      'unsupportedBackendReasonFor',
      'PlatformCapabilityMatrix.rows',
      'backendEnabled = isEnabled && unsupportedReason == null',
      'onTap: widget.isEnabled ? widget.onTap : null',
      'enabled: widget.isEnabled',
    ],
  ),
  _RequiredFile(
    path:
        'packages/skotiq_app/test/screens/equipment/backend_selector_chips_test.dart',
    label: 'Backend selector platform gating tests',
    requiredText: [
      'unsupportedBackendReasonFor gates ASCOM COM off Linux',
      'BackendSelectorChips disables unsupported platform backends',
      'PlatformCapabilityMatrix.linux',
      // The unsupported-backend indicator icon is LucideIcons.ban; the gating
      // assertion checks the disabled-backend icon is rendered.
      'LucideIcons.ban',
    ],
  ),
  _RequiredFile(
    path:
        'packages/skotiq_app/lib/screens/settings/widgets/connection_settings.dart',
    label: 'Settings platform capability view',
    requiredText: [
      'PlatformCapabilityMatrix.forPlatform(Platform.operatingSystem)',
      // The shipped label, sentence case since the Observatory sweep. This
      // anchor tracks what the screen actually says; it is not a style rule.
      'Platform capabilities',
      'Current platform:',
      'statusFor(platform)',
      'Capability-gated',
      'unsupportedReason',
      'deviceCoverage',
    ],
  ),
  _RequiredFile(
    path:
        'packages/skotiq_app/test/screens/settings/platform_capabilities_settings_test.dart',
    label: 'Settings platform capability tests',
    requiredText: [
      'Connection settings render release-scoped platform capabilities',
      'Platform capabilities',
      'ASCOM COM',
      'Native SDK',
      'Capability-gated',
      'reachable INDI server',
      'Simulator',
    ],
  ),
  _RequiredFile(
    path: 'docs/supported-hardware-by-platform.md',
    label: 'Supported hardware platform docs',
    requiredText: [
      '## Driver Backend Availability',
      'ASCOM COM | Available | Unsupported | Unsupported',
      'ASCOM Alpaca | Available | Available | Available',
      'INDI | Available | Available | Available',
      'Native SDK | Capability-gated | Capability-gated | Capability-gated',
      'Simulator | Capability-gated | Capability-gated | Capability-gated',
      '## Linux Packaging And Permissions',
      'native shared libraries',
      'udev rules',
      'dialout',
      'plugdev',
      'video',
      'DSLR/gphoto2',
      '/api/info.platformCapabilities',
      'in-app Platform Capabilities',
    ],
  ),
  _RequiredFile(
    path: 'docs/production-readiness/feature-parity-matrix.md',
    label: 'Feature parity platform matrix',
    requiredText: [
      '## Driver Backend Platform Matrix',
      'ASCOM COM | Available | Unsupported | Unsupported',
      'ASCOM Alpaca | Available | Available | Available',
      'INDI | Available | Available | Available',
      'Native SDK | Capability-gated | Capability-gated | Capability-gated',
      'Simulator | Capability-gated | Capability-gated | Capability-gated',
      '/api/info',
      'platformCapabilities',
      'Unsupported',
      'controls disabled',
    ],
  ),
  _RequiredFile(
    path: 'docs/api/web-server-api.md',
    label: 'Headless API docs',
    requiredText: [
      'platformCapabilities',
      'ASCOM COM',
      'supportedPlatforms',
      'unsupportedReason',
      'GET /api/equipment/camera/capabilities',
      'GET /api/equipment/mount/capabilities',
      'GET /api/equipment/focuser/capabilities',
      'GET /api/equipment/filter-wheel/capabilities',
      'GET /api/equipment/rotator/capabilities',
      'capability response is device-specific',
    ],
  ),
];

Future<void> main(List<String> args) async {
  final root = Directory(_argValue(args, '--root') ?? Directory.current.path);
  final jsonOut = _argValue(args, '--json-out') ?? _defaultJsonOutputPath;
  final markdownOut = _argValue(args, '--md-out') ?? _defaultMarkdownOutputPath;
  final failOnIssue = !args.contains('--no-fail-on-issue');

  final fileReports = [
    for (final required in _requiredFiles) _auditFile(root, required),
  ];
  final issues = [for (final report in fileReports) ...report.issues];
  final passed = issues.isEmpty;
  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'fileCount': fileReports.length,
    'issueCount': issues.length,
    'issues': issues,
    'files': fileReports.map((report) => report.toJson()).toList(),
    'policy':
        'Platform capability clarity requires a shared model, headless API exposure, settings UI visibility, backend selector gating, docs, and tests to stay aligned for ASCOM, Alpaca, INDI, Native SDK, and simulator availability.',
  };

  await File(jsonOut).parent.create(recursive: true);
  await File(
    jsonOut,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(markdownOut).parent.create(recursive: true);
  await File(markdownOut).writeAsString(
    _renderMarkdown(passed: passed, fileReports: fileReports, issues: issues),
  );

  stdout.writeln('Platform capability audit complete.');
  stdout.writeln('Passed: $passed');
  stdout.writeln('Files: ${fileReports.length}');
  stdout.writeln('Issues: ${issues.length}');
  stdout.writeln('JSON: $jsonOut');
  stdout.writeln('Markdown: $markdownOut');

  if (failOnIssue && !passed) {
    exit(1);
  }
}

_FileReport _auditFile(Directory root, _RequiredFile required) {
  final file = File('${root.path}/${required.path}');
  if (!file.existsSync()) {
    return _FileReport(
      path: required.path,
      label: required.label,
      exists: false,
      missingText: required.requiredText,
      sizeBytes: 0,
    );
  }

  final text = file.readAsStringSync();
  return _FileReport(
    path: required.path,
    label: required.label,
    exists: true,
    missingText: [
      for (final requiredText in required.requiredText)
        if (!text.contains(requiredText)) requiredText,
    ],
    sizeBytes: file.lengthSync(),
  );
}

String _renderMarkdown({
  required bool passed,
  required List<_FileReport> fileReports,
  required List<String> issues,
}) {
  final buffer = StringBuffer()
    ..writeln('# Platform Capability Audit')
    ..writeln()
    ..writeln('- Passed: `$passed`')
    ..writeln('- Files: `${fileReports.length}`')
    ..writeln('- Issues: `${issues.length}`')
    ..writeln()
    ..writeln(
      'This audit checks that platform capability support is visible and aligned across the shared model, headless API responses, settings UI, backend selector gating, docs, and tests.',
    )
    ..writeln()
    ..writeln('## Files')
    ..writeln()
    ..writeln('| File | Exists | Missing required text |')
    ..writeln('| --- | --- | ---: |');

  for (final report in fileReports) {
    buffer.writeln(
      '| `${report.path}` | `${report.exists}` | `${report.missingText.length}` |',
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

class _RequiredFile {
  final String path;
  final String label;
  final List<String> requiredText;

  const _RequiredFile({
    required this.path,
    required this.label,
    required this.requiredText,
  });
}

class _FileReport {
  final String path;
  final String label;
  final bool exists;
  final List<String> missingText;
  final int sizeBytes;

  const _FileReport({
    required this.path,
    required this.label,
    required this.exists,
    required this.missingText,
    required this.sizeBytes,
  });

  List<String> get issues {
    if (!exists) {
      return ['Missing platform capability evidence file: $path'];
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
