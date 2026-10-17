import 'dart:convert';
import 'dart:io';

const _defaultJsonOutputPath =
    'docs/production-readiness/developer-quality-audit.json';
const _defaultMarkdownOutputPath =
    'docs/production-readiness/developer-quality-audit.md';

const _uiAuditPath = 'docs/production-readiness/ui-consistency-audit.json';
const _routePolicyPath =
    'docs/production-readiness/headless-route-policy-audit.json';
const _apiContractPath =
    'docs/production-readiness/headless-api-contract-audit.json';
const _responseHelperPath =
    'docs/production-readiness/headless-response-helper-audit.json';
const _oversizedAuditPath =
    'docs/production-readiness/oversized-file-audit.json';
const _loggingServicePath =
    'packages/skotiq_core/lib/src/services/logging_service.dart';
const _loggingServiceTestPath =
    'packages/skotiq_core/test/services/logging_service_test.dart';
const _headlessServerPath = 'apps/desktop/lib/headless_api_server.dart';
const _headlessServerPartsDirectory = 'apps/desktop/lib/headless_api_server';
const _networkBackendPath =
    'packages/skotiq_core/lib/src/backend/network_backend.dart';
const _networkBackendPartsDirectory =
    'packages/skotiq_core/lib/src/backend/network_backend';

Future<void> main(List<String> args) async {
  final root = Directory(_argValue(args, '--root') ?? Directory.current.path);
  final jsonOut = _argValue(args, '--json-out') ?? _defaultJsonOutputPath;
  final markdownOut = _argValue(args, '--md-out') ?? _defaultMarkdownOutputPath;
  final failOnIssue = !args.contains('--no-fail-on-issue');

  final ui = _uiQuality(root);
  final apiContract = _apiContractQuality(root);
  final routes = _routeQuality(root);
  final responses = _responseHelperQuality(root);
  final oversized = _oversizedQuality(root);
  final structuredLogging = _structuredLoggingQuality(root);
  final checks = [
    ui,
    apiContract,
    routes,
    responses,
    oversized,
    structuredLogging,
  ];
  final issues = [for (final check in checks) ...check.issues];
  final passed = issues.isEmpty;

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'issueCount': issues.length,
    'issues': issues,
    'checks': checks.map((check) => check.toJson()).toList(),
    'policy':
        'Developer quality is blocked by UI consistency blocking findings, headless API contract drift, headless route policy issues, missing headless response helper coverage, or missing structured request/audit logging correlation fields. Oversized files are tracked as planning risk, not a release blocker by this rollup.',
  };

  await File(jsonOut).parent.create(recursive: true);
  await File(
    jsonOut,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(markdownOut).parent.create(recursive: true);
  await File(markdownOut).writeAsString(
    _renderMarkdown(passed: passed, checks: checks, issues: issues),
  );

  stdout.writeln('Developer quality audit complete.');
  stdout.writeln('Passed: $passed');
  stdout.writeln('Issues: ${issues.length}');
  stdout.writeln('JSON: $jsonOut');
  stdout.writeln('Markdown: $markdownOut');

  if (failOnIssue && !passed) {
    exit(1);
  }
}

_QualityCheck _uiQuality(Directory root) {
  final data = _readJson(root, _uiAuditPath);
  if (data == null) {
    return const _QualityCheck(
      id: 'ui_consistency',
      label: 'UI consistency rules',
      evidence: _uiAuditPath,
      passed: false,
      metrics: {},
      issues: ['UI consistency audit artifact is missing.'],
    );
  }

  final findingCount = (data['findingCount'] as num?)?.toInt() ?? 0;
  final blockingFindingCount =
      (data['blockingFindingCount'] as num?)?.toInt() ?? 0;
  final countsByRule = data['countsByRule'] as Map<String, dynamic>? ?? {};
  final rawColorClassifications =
      data['rawColorClassifications'] as Map<String, dynamic>? ?? {};
  final designSystemGallery =
      data['designSystemGallery'] as Map<String, dynamic>? ?? {};
  final semanticRawColors =
      (rawColorClassifications['semantic_theme_color'] as num?)?.toInt() ?? 0;
  final intentionalOverlayColors =
      (rawColorClassifications['intentional_image_overlay'] as num?)?.toInt() ??
      0;
  final rawColorCount =
      (countsByRule['raw_material_color'] as num?)?.toInt() ??
      semanticRawColors + intentionalOverlayColors;

  final issues = <String>[];
  if (blockingFindingCount != 0) {
    issues.add('UI consistency blocking findings=$blockingFindingCount.');
  }
  if (semanticRawColors != 0) {
    issues.add('Semantic raw Material color findings=$semanticRawColors.');
  }
  if (designSystemGallery['ready'] != true) {
    issues.add('Design-system gallery evidence is incomplete.');
  }
  final classifiedRawColors = rawColorClassifications.values.fold<int>(
    0,
    (sum, value) => sum + ((value as num?)?.toInt() ?? 0),
  );
  if (rawColorCount != classifiedRawColors) {
    issues.add(
      'Raw Material color classification count mismatch: raw=$rawColorCount classified=$classifiedRawColors.',
    );
  }

  return _QualityCheck(
    id: 'ui_consistency',
    label: 'UI consistency rules',
    evidence: _uiAuditPath,
    passed: issues.isEmpty,
    metrics: {
      'findingCount': findingCount,
      'blockingFindingCount': blockingFindingCount,
      'rawButtonStyle':
          (countsByRule['raw_button_style'] as num?)?.toInt() ?? 0,
      'largeRadius': (countsByRule['large_radius'] as num?)?.toInt() ?? 0,
      'emptyCallback': (countsByRule['empty_callback'] as num?)?.toInt() ?? 0,
      'fakeCallback': (countsByRule['fake_callback'] as num?)?.toInt() ?? 0,
      'stubCallback': (countsByRule['stub_callback'] as num?)?.toInt() ?? 0,
      'headlessRouteNotAdvertised':
          (countsByRule['headless_route_not_advertised'] as num?)?.toInt() ?? 0,
      'designSystemGalleryReady': designSystemGallery['ready'] == true,
      'designSystemGalleryMissing':
          (countsByRule['design_system_gallery_missing'] as num?)?.toInt() ?? 0,
      'rawMaterialColor': rawColorCount,
      'semanticRawMaterialColor': semanticRawColors,
      'intentionalImageOverlayColor': intentionalOverlayColors,
    },
    issues: issues,
  );
}

_QualityCheck _apiContractQuality(Directory root) {
  final data = _readJson(root, _apiContractPath);
  if (data == null) {
    return const _QualityCheck(
      id: 'headless_api_contract',
      label: 'Headless API contract',
      evidence: _apiContractPath,
      passed: false,
      metrics: {},
      issues: ['Headless API contract audit artifact is missing.'],
    );
  }

  final networkBackendMissingOnServer =
      (data['networkBackendMissingOnServerCount'] as num?)?.toInt() ?? 0;
  final registeredNotAdvertised =
      (data['registeredNotAdvertisedCount'] as num?)?.toInt() ?? 0;
  final advertisedNotRegistered =
      (data['advertisedNotRegisteredCount'] as num?)?.toInt() ?? 0;
  final advertisedHttpMissingOpenApi =
      (data['advertisedHttpMissingOpenApiCount'] as num?)?.toInt() ?? 0;
  final openApiMetadata =
      data['openApiMetadataCoverage'] as Map<String, dynamic>? ?? const {};
  final webSocketContract =
      data['webSocketContractCoverage'] as Map<String, dynamic>? ?? const {};
  final networkBackendContract =
      data['networkBackendContractCoverage'] as Map<String, dynamic>? ??
      const {};
  final versionNegotiation =
      data['versionNegotiationCoverage'] as Map<String, dynamic>? ?? const {};

  final issues = <String>[];
  if (data['passed'] != true) {
    issues.add('Headless API contract audit did not pass.');
  }
  if (registeredNotAdvertised != 0 ||
      advertisedNotRegistered != 0 ||
      networkBackendMissingOnServer != 0 ||
      advertisedHttpMissingOpenApi != 0) {
    issues.add(
      'Headless API route drift detected: registeredNotAdvertised=$registeredNotAdvertised '
      'advertisedNotRegistered=$advertisedNotRegistered '
      'networkBackendMissingOnServer=$networkBackendMissingOnServer '
      'advertisedHttpMissingOpenApi=$advertisedHttpMissingOpenApi.',
    );
  }
  if (openApiMetadata.values.any((present) => present != true) ||
      webSocketContract.values.any((present) => present != true) ||
      networkBackendContract.values.any((present) => present != true) ||
      versionNegotiation.values.any((present) => present != true)) {
    issues.add('Headless API contract coverage markers are incomplete.');
  }

  return _QualityCheck(
    id: 'headless_api_contract',
    label: 'Headless API contract',
    evidence: _apiContractPath,
    passed: issues.isEmpty,
    metrics: {
      'registeredRouteCount':
          (data['registeredRouteCount'] as num?)?.toInt() ?? 0,
      'advertisedRouteCount':
          (data['advertisedRouteCount'] as num?)?.toInt() ?? 0,
      'openApiOperationCount':
          (data['openApiOperationCount'] as num?)?.toInt() ?? 0,
      'networkBackendRouteCount':
          (data['networkBackendRouteCount'] as num?)?.toInt() ?? 0,
      'networkBackendMissingOnServer': networkBackendMissingOnServer,
      'openApiMetadataCoverage':
          '${openApiMetadata.values.where((present) => present == true).length}/${openApiMetadata.length}',
      'webSocketContractCoverage':
          '${webSocketContract.values.where((present) => present == true).length}/${webSocketContract.length}',
      'networkBackendContractCoverage':
          '${networkBackendContract.values.where((present) => present == true).length}/${networkBackendContract.length}',
      'versionNegotiationCoverage':
          '${versionNegotiation.values.where((present) => present == true).length}/${versionNegotiation.length}',
    },
    issues: issues,
  );
}

_QualityCheck _routeQuality(Directory root) {
  final data = _readJson(root, _routePolicyPath);
  if (data == null) {
    return const _QualityCheck(
      id: 'headless_route_policy',
      label: 'Headless route policy',
      evidence: _routePolicyPath,
      passed: false,
      metrics: {},
      issues: ['Headless route policy audit artifact is missing.'],
    );
  }
  final issueCount = (data['issueCount'] as num?)?.toInt() ?? 0;
  final highRiskPolicyCount =
      (data['highRiskPolicyCount'] as num?)?.toInt() ?? 0;
  final defaultLimitedPolicyCount =
      (data['defaultLimitedPolicyCount'] as num?)?.toInt() ?? 0;
  final serverMiddlewareTests =
      data['serverMiddlewareTests'] as Map<String, dynamic>? ?? const {};
  final bodyLimits = data['bodyLimits'] as Map<String, dynamic>? ?? const {};
  final bodyLimitedApiWriteRouteCount =
      (data['bodyLimitedApiWriteRouteCount'] as num?)?.toInt() ?? 0;
  final serverMiddlewareTestCount =
      (data['serverMiddlewareTestCount'] as num?)?.toInt() ??
      serverMiddlewareTests.values.where((present) => present == true).length;
  final issues = <String>[];
  if (data['passed'] != true || issueCount != 0) {
    issues.add('Headless route policy issues=$issueCount.');
  }
  if (serverMiddlewareTests.isEmpty ||
      serverMiddlewareTests.values.any((present) => present != true)) {
    issues.add('Headless server middleware enforcement tests are incomplete.');
  }
  if (bodyLimitedApiWriteRouteCount <= 0) {
    issues.add('Headless body-capable API route limit coverage is missing.');
  }
  return _QualityCheck(
    id: 'headless_route_policy',
    label: 'Headless route policy',
    evidence: _routePolicyPath,
    passed: issues.isEmpty,
    metrics: {
      'issueCount': issueCount,
      'highRiskPolicyCount': highRiskPolicyCount,
      'defaultLimitedPolicyCount': defaultLimitedPolicyCount,
      'ordinaryReadLimited': data['ordinaryReadLimited'] == true,
      'fileBrowseAuditAction': data['fileBrowseAuditAction'],
      'bodyLimitRouteCount': bodyLimits.length,
      'bodyLimitedApiWriteRouteCount': bodyLimitedApiWriteRouteCount,
      'serverMiddlewareTestCount': serverMiddlewareTestCount,
    },
    issues: issues,
  );
}

_QualityCheck _responseHelperQuality(Directory root) {
  final data = _readJson(root, _responseHelperPath);
  if (data == null) {
    return const _QualityCheck(
      id: 'headless_response_helpers',
      label: 'Headless response helpers',
      evidence: _responseHelperPath,
      passed: false,
      metrics: {},
      issues: ['Headless response helper audit artifact is missing.'],
    );
  }
  final issueCount = (data['issueCount'] as num?)?.toInt() ?? 0;
  final usage = data['usage'] as Map<String, dynamic>? ?? const {};
  final unclassifiedRawResponses =
      (usage['unclassifiedRawResponseCallCount'] as num?)?.toInt() ?? 0;
  final issues = <String>[];
  if (data['passed'] != true || issueCount != 0) {
    issues.add('Headless response helper audit issues=$issueCount.');
  }
  if (unclassifiedRawResponses != 0) {
    issues.add(
      'Unclassified raw headless Response calls=$unclassifiedRawResponses.',
    );
  }
  return _QualityCheck(
    id: 'headless_response_helpers',
    label: 'Headless response helpers',
    evidence: _responseHelperPath,
    passed: issues.isEmpty,
    metrics: {
      'issueCount': issueCount,
      'rawResponseCallCount':
          (usage['rawResponseCallCount'] as num?)?.toInt() ?? 0,
      'intentionalRawResponseCallCount':
          (usage['intentionalRawResponseCallCount'] as num?)?.toInt() ?? 0,
      'unclassifiedRawResponseCallCount': unclassifiedRawResponses,
      'jsonContentTypeCount':
          (usage['jsonContentTypeCount'] as num?)?.toInt() ?? 0,
      'helperImportCount': (usage['helperImportCount'] as num?)?.toInt() ?? 0,
      'helperCallCount': (usage['helperCallCount'] as num?)?.toInt() ?? 0,
    },
    issues: issues,
  );
}

_QualityCheck _oversizedQuality(Directory root) {
  final data = _readJson(root, _oversizedAuditPath);
  if (data == null) {
    return const _QualityCheck(
      id: 'oversized_files',
      label: 'Oversized files',
      evidence: _oversizedAuditPath,
      passed: false,
      metrics: {},
      issues: ['Oversized file audit artifact is missing.'],
    );
  }
  final scannedFileCount = (data['scannedFileCount'] as num?)?.toInt() ?? 0;
  final warningFileCount = (data['warningFileCount'] as num?)?.toInt() ?? 0;
  final criticalFileCount = (data['criticalFileCount'] as num?)?.toInt() ?? 0;
  final prioritySplitCandidateCount =
      (data['prioritySplitCandidateCount'] as num?)?.toInt() ?? 0;
  final modularizedSourceFamilyCount =
      (data['modularizedSourceFamilyCount'] as num?)?.toInt() ?? 0;
  final issues = <String>[];
  if (scannedFileCount <= 0) {
    issues.add('Oversized file audit scanned no files.');
  }
  return _QualityCheck(
    id: 'oversized_files',
    label: 'Oversized files',
    evidence: _oversizedAuditPath,
    passed: issues.isEmpty,
    metrics: {
      'scannedFileCount': scannedFileCount,
      'warningFileCount': warningFileCount,
      'criticalFileCount': criticalFileCount,
      'prioritySplitCandidateCount': prioritySplitCandidateCount,
      'modularizedSourceFamilyCount': modularizedSourceFamilyCount,
      'warningLineLimit': (data['warningLineLimit'] as num?)?.toInt(),
      'criticalLineLimit': (data['criticalLineLimit'] as num?)?.toInt(),
      'releaseBlocking': false,
    },
    issues: issues,
  );
}

_QualityCheck _structuredLoggingQuality(Directory root) {
  final requiredFiles = {
    _loggingServicePath: [
      'final Map<String, Object?> fields;',
      'Map<String, Object?>? fields',
      'jsonEncode(_jsonSafe(fields))',
      'fields: fields',
    ],
    _loggingServiceTestPath: [
      'records structured fields on log entries',
      "'requestId': 'req-1'",
      'entry.fields',
    ],
    _headlessServerPath: [
      "'requestId': requestId",
      "'elapsedMs': elapsedMs",
      "'auditAction': auditAction",
      "'phase': 'completed'",
    ],
    _networkBackendPath: [
      "static const _requestIdHeader = 'x-request-id';",
      "_NetworkBackendTransport._requestIdHeader: _nextRequestId('compat'),",
      'headers[_NetworkBackendTransport._requestIdHeader] =',
      'RemoteApiCompatibility.apiVersionHeader',
    ],
  };

  final issues = <String>[];
  var missingTextCount = 0;
  for (final entry in requiredFiles.entries) {
    final file = File('${root.path}/${entry.key}');
    if (!file.existsSync()) {
      issues.add('Structured logging required file is missing: ${entry.key}.');
      missingTextCount += entry.value.length;
      continue;
    }
    final text = switch (entry.key) {
      _headlessServerPath => _readSourceTree(
        root,
        file,
        _headlessServerPartsDirectory,
      ),
      _networkBackendPath => _readSourceTree(
        root,
        file,
        _networkBackendPartsDirectory,
      ),
      _ => file.readAsStringSync(),
    };
    for (final requiredText in entry.value) {
      if (!text.contains(requiredText)) {
        issues.add(
          '${entry.key} is missing structured logging text: `$requiredText`.',
        );
        missingTextCount++;
      }
    }
  }

  return _QualityCheck(
    id: 'structured_logging',
    label: 'Structured request/audit logging',
    evidence:
        '$_loggingServicePath; $_loggingServiceTestPath; $_headlessServerPath; $_networkBackendPath',
    passed: issues.isEmpty,
    metrics: {
      'requiredFileCount': requiredFiles.length,
      'missingTextCount': missingTextCount,
      'requestCorrelationFieldsRequired': true,
      'auditCorrelationFieldsRequired': true,
      'networkBackendCorrelationRequired': true,
    },
    issues: issues,
  );
}

String _readSourceTree(Directory root, File source, String partsPath) {
  final sources = <String>[source.readAsStringSync()];
  final partsDirectory = Directory('${root.path}/$partsPath');
  if (!partsDirectory.existsSync()) {
    return sources.single;
  }
  final partFiles =
      partsDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in partFiles) {
    sources.add(file.readAsStringSync());
  }
  return sources.join('\n');
}

String _renderMarkdown({
  required bool passed,
  required List<_QualityCheck> checks,
  required List<String> issues,
}) {
  final buffer = StringBuffer()
    ..writeln('# Developer Quality Audit')
    ..writeln()
    ..writeln('- Passed: `$passed`')
    ..writeln('- Issues: `${issues.length}`')
    ..writeln()
    ..writeln(
      'This rollup consumes UI consistency, headless API contract, headless route policy, headless response helper, oversized-file, and structured logging evidence. It fails on blocking UI, API contract, route-policy, response-helper, or correlation logging regressions. Oversized files remain planning evidence.',
    )
    ..writeln()
    ..writeln('## Checks')
    ..writeln()
    ..writeln('| Status | Check | Evidence | Metrics |')
    ..writeln('| --- | --- | --- | --- |');

  for (final check in checks) {
    buffer.writeln(
      '| ${check.passed ? 'PASS' : 'FAIL'} | ${check.label} | '
      '`${check.evidence}` | ${_metricsText(check.metrics)} |',
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

String _metricsText(Map<String, Object?> metrics) {
  if (metrics.isEmpty) return 'none';
  return metrics.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ')
      .replaceAll('|', r'\|');
}

Map<String, dynamic>? _readJson(Directory root, String path) {
  final file = File('${root.path}/$path');
  if (!file.existsSync()) return null;
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
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

class _QualityCheck {
  final String id;
  final String label;
  final String evidence;
  final bool passed;
  final Map<String, Object?> metrics;
  final List<String> issues;

  const _QualityCheck({
    required this.id,
    required this.label,
    required this.evidence,
    required this.passed,
    required this.metrics,
    required this.issues,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'evidence': evidence,
    'passed': passed,
    'metrics': metrics,
    'issues': issues,
  };
}
