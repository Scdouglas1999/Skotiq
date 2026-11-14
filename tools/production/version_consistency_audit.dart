import 'dart:convert';
import 'dart:io';

/// Version-consistency gate.
///
/// A published release is identified by its version string in four places that
/// must agree, or an OTA package, an artifact filename, the installer, and the
/// binary-reported version can silently denote different releases:
///
///   * `version.yaml`            — single source of truth read by the OTA
///     package builder (`scripts/build_update_package.ps1`) and the Linux
///     packaging script (`scripts/docker_build_linux.sh`).
///   * `apps/desktop/pubspec.yaml` — the desktop binary's reported version and
///     the version the release workflow validates the git tag against.
///   * `apps/mobile/pubspec.yaml`  — the mobile companion's reported version.
///   * `apps/desktop/installer/installer.iss` — the version the Windows
///     installer shows and registers (`MyAppVersion`; it has no build number).
///   * `packages/skotiq_remote_protocol/lib/src/link_version.dart` — the
///     release a linked client and its host compare (`skotiqRelease`).
///
/// This audit fails closed (exit 1) when those version strings disagree, when
/// their build numbers disagree, or when the OTA package builder no longer
/// sources its version from `version.yaml` (which would let the OTA manifest
/// version drift away from the desktop binary version).
const _versionYamlPath = 'version.yaml';
const _desktopPubspecPath = 'apps/desktop/pubspec.yaml';
const _mobilePubspecPath = 'apps/mobile/pubspec.yaml';
const _installerPath = 'apps/desktop/installer/installer.iss';
const _otaScriptPath = 'scripts/build_update_package.ps1';
const _linkReleasePath =
    'packages/skotiq_remote_protocol/lib/src/link_version.dart';

Future<void> main(List<String> args) async {
  final root = Directory(_argValue(args, '--root') ?? Directory.current.path);
  final jsonOut = _argValue(args, '--json-out');
  final failOnIssue = !args.contains('--no-fail-on-issue');

  final issues = <String>[];

  final versionYaml = _VersionSource.fromVersionYaml(
    root: root,
    path: _versionYamlPath,
    issues: issues,
  );
  final desktop = _VersionSource.fromPubspec(
    root: root,
    path: _desktopPubspecPath,
    issues: issues,
  );
  final mobile = _VersionSource.fromPubspec(
    root: root,
    path: _mobilePubspecPath,
    issues: issues,
  );
  final installer = _VersionSource.fromLine(
    root: root,
    path: _installerPath,
    pattern: RegExp(r'^#define\s+MyAppVersion\s+"([^"]+)"', multiLine: true),
    field: 'MyAppVersion',
    issues: issues,
  );
  final linkRelease = _VersionSource.fromLine(
    root: root,
    path: _linkReleasePath,
    pattern: RegExp(r"^const String skotiqRelease = '([^']+)';", multiLine: true),
    field: 'skotiqRelease',
    issues: issues,
  );

  // Version-string agreement across the declared sources.
  final versions = <String, String?>{
    _versionYamlPath: versionYaml.version,
    _desktopPubspecPath: desktop.version,
    _mobilePubspecPath: mobile.version,
    _installerPath: installer.version,
    _linkReleasePath: linkRelease.version,
  };
  final distinctVersions = versions.values.whereType<String>().toSet();
  if (distinctVersions.length > 1) {
    issues.add(
      'Version strings disagree across release sources: '
      '${versions.entries.map((e) => '${e.key}=${e.value ?? '<missing>'}').join(', ')}. '
      'Reconcile them to the version in $_versionYamlPath.',
    );
  }

  // Build-number agreement: the three sources must also denote the same build.
  final builds = <String, int?>{
    _versionYamlPath: versionYaml.buildNumber,
    _desktopPubspecPath: desktop.buildNumber,
    _mobilePubspecPath: mobile.buildNumber,
  };
  final distinctBuilds = builds.values.whereType<int>().toSet();
  if (distinctBuilds.length > 1) {
    issues.add(
      'Build numbers disagree across release sources: '
      '${builds.entries.map((e) => '${e.key}=${e.value ?? '<missing>'}').join(', ')}. '
      'Reconcile all three to a single build number.',
    );
  }

  // The OTA package builder must source its version from version.yaml so the
  // signed OTA manifest version equals the desktop binary version. If the
  // script stops reading version.yaml, the manifest version could silently
  // drift from the shipped binary.
  final ota = _OtaSource.fromScript(
    root: root,
    path: _otaScriptPath,
    issues: issues,
  );
  if (ota.exists && !ota.sourcesVersionFromVersionYaml) {
    issues.add(
      '$_otaScriptPath no longer derives its version from $_versionYamlPath; '
      'the OTA manifest version could drift from the desktop binary version.',
    );
  }
  // OTA manifest version == desktop binary version. The OTA builder reads
  // version.yaml, so version.yaml.version IS the OTA manifest version; assert it
  // matches the desktop pubspec version explicitly (the most load-bearing pair).
  if (ota.exists &&
      ota.sourcesVersionFromVersionYaml &&
      versionYaml.version != null &&
      desktop.version != null &&
      versionYaml.version != desktop.version) {
    issues.add(
      'OTA manifest version source ($_versionYamlPath=${versionYaml.version}) '
      'does not match the desktop binary version '
      '($_desktopPubspecPath=${desktop.version}).',
    );
  }

  final passed = issues.isEmpty;
  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'issueCount': issues.length,
    'issues': issues,
    'sources': {
      _versionYamlPath: versionYaml.toJson(),
      _desktopPubspecPath: desktop.toJson(),
      _mobilePubspecPath: mobile.toJson(),
      _installerPath: installer.toJson(),
      _linkReleasePath: linkRelease.toJson(),
      _otaScriptPath: ota.toJson(),
    },
    'distinctVersions': distinctVersions.toList()..sort(),
    'distinctBuildNumbers': distinctBuilds.toList()..sort(),
    'focusedVerification':
        'dart run tools/production/version_consistency_audit.dart',
  };

  if (jsonOut != null) {
    final outFile = File('${root.path}/$jsonOut');
    await outFile.parent.create(recursive: true);
    await outFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  }

  stdout.writeln('Version consistency audit complete.');
  stdout.writeln('Passed: $passed');
  stdout.writeln('Issues: ${issues.length}');
  stdout.writeln('version.yaml: ${versionYaml.summary}');
  stdout.writeln('desktop pubspec: ${desktop.summary}');
  stdout.writeln('mobile pubspec: ${mobile.summary}');
  stdout.writeln('installer: version=${installer.version ?? '<unparsed>'}');
  stdout.writeln(
    'link release: version=${linkRelease.version ?? '<unparsed>'}',
  );
  stdout.writeln('OTA builder: ${ota.summary}');
  for (final issue in issues) {
    stdout.writeln('  - $issue');
  }

  if (failOnIssue && !passed) {
    exit(1);
  }
}

/// A declared version source (version.yaml, a pubspec.yaml or installer.iss).
class _VersionSource {
  final String path;
  final bool exists;
  final String? version;
  final int? buildNumber;

  const _VersionSource({
    required this.path,
    required this.exists,
    required this.version,
    required this.buildNumber,
  });

  /// Parses `version.yaml`: `version: "5.0.0"` + `build_number: 23`.
  factory _VersionSource.fromVersionYaml({
    required Directory root,
    required String path,
    required List<String> issues,
  }) {
    final file = File('${root.path}/$path');
    if (!file.existsSync()) {
      issues.add('Missing required version source: $path');
      return _VersionSource(
        path: path,
        exists: false,
        version: null,
        buildNumber: null,
      );
    }
    final text = file.readAsStringSync();
    final version = _firstGroup(
      RegExp(r'''^version:\s*"?([^"#\s]+)"?''', multiLine: true),
      text,
    );
    final buildRaw = _firstGroup(
      RegExp(r'^build_number:\s*(\d+)', multiLine: true),
      text,
    );
    if (version == null) {
      issues.add('$path does not declare a parseable `version:` field.');
    }
    if (buildRaw == null) {
      issues.add('$path does not declare a parseable `build_number:` field.');
    }
    return _VersionSource(
      path: path,
      exists: true,
      version: version,
      buildNumber: buildRaw == null ? null : int.tryParse(buildRaw),
    );
  }

  /// Parses a pubspec: `version: 5.0.0+23`.
  factory _VersionSource.fromPubspec({
    required Directory root,
    required String path,
    required List<String> issues,
  }) {
    final file = File('${root.path}/$path');
    if (!file.existsSync()) {
      issues.add('Missing required version source: $path');
      return _VersionSource(
        path: path,
        exists: false,
        version: null,
        buildNumber: null,
      );
    }
    final text = file.readAsStringSync();
    final raw = _firstGroup(
      RegExp(r'^version:\s*(\S+)', multiLine: true),
      text,
    );
    if (raw == null) {
      issues.add('$path does not declare a parseable `version:` field.');
      return _VersionSource(
        path: path,
        exists: true,
        version: null,
        buildNumber: null,
      );
    }
    final plus = raw.indexOf('+');
    final version = plus >= 0 ? raw.substring(0, plus) : raw;
    final buildRaw = plus >= 0 ? raw.substring(plus + 1) : null;
    return _VersionSource(
      path: path,
      exists: true,
      version: version,
      buildNumber: buildRaw == null ? null : int.tryParse(buildRaw),
    );
  }

  /// Parses a source that names the version on one line, with no build
  /// number: the first group of [pattern] is the version.
  factory _VersionSource.fromLine({
    required Directory root,
    required String path,
    required RegExp pattern,
    required String field,
    required List<String> issues,
  }) {
    final file = File('${root.path}/$path');
    if (!file.existsSync()) {
      issues.add('Missing required version source: $path');
      return _VersionSource(
        path: path,
        exists: false,
        version: null,
        buildNumber: null,
      );
    }
    final version = _firstGroup(pattern, file.readAsStringSync());
    if (version == null) {
      issues.add('$path does not declare a parseable `$field`.');
    }
    return _VersionSource(
      path: path,
      exists: true,
      version: version,
      buildNumber: null,
    );
  }

  String get summary => exists
      ? 'version=${version ?? '<unparsed>'} build=${buildNumber ?? '<unparsed>'}'
      : '<missing>';

  Map<String, Object?> toJson() => {
    'path': path,
    'exists': exists,
    'version': version,
    'buildNumber': buildNumber,
  };
}

/// The OTA package builder script, used to confirm the OTA manifest version is
/// derived from version.yaml (so it cannot drift from the desktop binary).
class _OtaSource {
  final String path;
  final bool exists;
  final bool sourcesVersionFromVersionYaml;

  const _OtaSource({
    required this.path,
    required this.exists,
    required this.sourcesVersionFromVersionYaml,
  });

  factory _OtaSource.fromScript({
    required Directory root,
    required String path,
    required List<String> issues,
  }) {
    final file = File('${root.path}/$path');
    if (!file.existsSync()) {
      issues.add('Missing required OTA package builder: $path');
      return _OtaSource(
        path: path,
        exists: false,
        sourcesVersionFromVersionYaml: false,
      );
    }
    final text = file.readAsStringSync();
    // The builder reads version.yaml and extracts the `version:` field from it.
    final readsVersionYaml = RegExp(
      r'''Get-Content\s+"?version\.yaml"?''',
    ).hasMatch(text);
    final extractsVersion = RegExp(
      r'''Match\(\$versionYaml,\s*'version:''',
    ).hasMatch(text);
    return _OtaSource(
      path: path,
      exists: true,
      sourcesVersionFromVersionYaml: readsVersionYaml && extractsVersion,
    );
  }

  String get summary => exists
      ? 'version-source=${sourcesVersionFromVersionYaml ? 'version.yaml' : 'UNKNOWN'}'
      : '<missing>';

  Map<String, Object?> toJson() => {
    'path': path,
    'exists': exists,
    'sourcesVersionFromVersionYaml': sourcesVersionFromVersionYaml,
  };
}

String? _firstGroup(RegExp re, String text) {
  final match = re.firstMatch(text);
  if (match == null) {
    return null;
  }
  return match.group(1);
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
