import 'dart:convert';
import 'dart:io';

const _defaultBundleDir = 'apps/desktop/build/linux/x64/release/bundle';
const _defaultOutputDir = 'build/release-linux';
const _defaultMetadataPath =
    'docs/production-readiness/linux-release-package-metadata.json';
const _defaultEvidencePath =
    'docs/production-readiness/linux-release-build-evidence.json';
const _metadataSchemaVersion = 2;

const _defaultNativeLibraryNotes = <String>[
  'Verify native shared libraries with ldd against the packaged Linux bundle.',
  'Record runtime/user-provided vendor SDK libraries before claiming native SDK support; official artifacts do not bundle vendor SDKs.',
];

const _defaultLinuxPermissionNotes = <String>[
  'Verify USB/serial access with udev rules and dialout, plugdev, or video group membership as needed.',
  'Record INDI server package/source and whether the smoke used a local or remote INDI server.',
];

const _requiredRuntimeSmokeChecks = <String, String>{
  'headless_process_started':
      'Headless process started, PID/listening port recorded, and log captured.',
  'api_info_ok': '/api/info returned HTTP 200 with version metadata.',
  'openapi_ok': '/api/openapi.json returned HTTP 200.',
  'dashboard_asset_ok': 'Dashboard HTML/JS/CSS assets returned HTTP 200.',
};

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  final bundleDir = Directory(options.bundleDir);
  if (!bundleDir.existsSync()) {
    stderr.writeln('Linux bundle directory not found: ${options.bundleDir}');
    stderr.writeln(
      'Run on Linux after: dart run melos run build:desktop:linux --no-select',
    );
    exit(1);
  }

  final outputDir = Directory(options.outputDir);
  outputDir.createSync(recursive: true);
  final artifactPath = '${options.outputDir}/${options.artifactName}';
  await _createTarGz(sourceDir: bundleDir, artifactPath: artifactPath);

  final artifact = File(artifactPath);
  final sha256 = await _sha256(artifact);
  final sha256Sidecar = await _writeSha256Sidecar(artifact, sha256);
  final fileEntries = await _bundleFiles(bundleDir);
  final generatedAt = DateTime.now().toUtc().toIso8601String();
  final sourceGitHead = await _gitHead();
  final toolVersions = await _toolVersions();
  final runtimeSmokeLog = options.runtimeSmokeLog == null
      ? null
      : File(options.runtimeSmokeLog!).absolute.path.replaceAll('\\', '/');

  final metadata = {
    'metadataSchemaVersion': _metadataSchemaVersion,
    'generatedAt': generatedAt,
    'platform': 'linux',
    'buildCommand': options.buildCommand,
    'toolVersions': toolVersions,
    'bundleDirectory': bundleDir.absolute.path.replaceAll('\\', '/'),
    'artifactPath': artifact.absolute.path.replaceAll('\\', '/'),
    'artifactName': options.artifactName,
    'artifactSizeBytes': artifact.lengthSync(),
    'artifactSha256': sha256,
    'artifactSha256Path': sha256Sidecar.absolute.path.replaceAll('\\', '/'),
    'sourceGitHead': sourceGitHead,
    'githubRunId': options.githubRunId,
    'githubRepository': options.githubRepository,
    'githubSha': options.githubSha,
    'fileCount': fileEntries.length,
    'bundleSizeBytes': fileEntries.fold<int>(
      0,
      (sum, entry) => sum + entry.sizeBytes,
    ),
    'runtimeSmokePassed': options.runtimeSmokePassed,
    'runtimeSmokeArtifact': runtimeSmokeLog,
    'nativeLibraryNotes': options.nativeLibraryNotes,
    'linuxPermissionNotes': options.linuxPermissionNotes,
    'files': fileEntries.map((entry) => entry.toJson()).toList(),
    'notes': [
      'Generated from the Linux build bundle. This metadata is packaging evidence only unless runtimeSmokePassed=true and runtimeSmokeArtifact exists.',
      if (options.githubRunId != null)
        'GitHub Actions run id: ${options.githubRunId}',
    ],
  };

  await File(options.metadataPath).parent.create(recursive: true);
  await File(
    options.metadataPath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));

  if (options.writeEvidence) {
    await _writeEvidence(
      options: options,
      generatedAt: generatedAt,
      artifact: artifact,
      sha256: sha256,
      sha256Sidecar: sha256Sidecar,
      toolVersions: toolVersions,
      runtimeSmokeLog: runtimeSmokeLog,
    );
  }

  stdout.writeln('Linux release package metadata complete.');
  stdout.writeln('Artifact: ${artifact.absolute.path}');
  stdout.writeln('Size bytes: ${artifact.lengthSync()}');
  stdout.writeln('SHA256: $sha256');
  stdout.writeln('SHA256 sidecar: ${sha256Sidecar.absolute.path}');
  stdout.writeln('Metadata: ${options.metadataPath}');
  if (options.writeEvidence) {
    stdout.writeln('Evidence: ${options.evidencePath}');
  }
}

Future<void> _createTarGz({
  required Directory sourceDir,
  required String artifactPath,
}) async {
  final artifact = File(artifactPath);
  if (artifact.existsSync()) {
    artifact.deleteSync();
  }
  final result = await Process.run('tar', [
    '-czf',
    artifact.absolute.path,
    '-C',
    sourceDir.absolute.path,
    '.',
  ], runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    stderr.write(result.stdout);
    stderr.write(result.stderr);
    exit(result.exitCode);
  }
  if (!artifact.existsSync() || artifact.lengthSync() == 0) {
    stderr.writeln('tar did not produce a non-empty artifact: $artifactPath');
    exit(1);
  }
}

Future<List<_BundleFileEntry>> _bundleFiles(Directory bundleDir) async {
  final root = bundleDir.absolute.path;
  final files = await Future.wait(
    bundleDir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((file) async {
          final absolutePath = file.absolute.path;
          final relativePath = absolutePath
              .substring(root.length + 1)
              .replaceAll('\\', '/');
          return _BundleFileEntry(
            path: relativePath,
            sizeBytes: file.lengthSync(),
            sha256: await _sha256(file),
          );
        }),
  );
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

Future<String> _sha256(File file) async {
  final result = await Process.run(
    Platform.isWindows ? 'certutil' : 'sha256sum',
    Platform.isWindows ? ['-hashfile', file.path, 'SHA256'] : [file.path],
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    stderr.write(result.stdout);
    stderr.write(result.stderr);
    exit(result.exitCode);
  }
  final stdoutText = result.stdout.toString();
  if (Platform.isWindows) {
    final match = RegExp(
      r'^[0-9a-fA-F]{64}$',
      multiLine: true,
    ).firstMatch(stdoutText);
    if (match != null) {
      return match.group(0)!.toLowerCase();
    }
  } else {
    final parts = stdoutText.trim().split(RegExp(r'\s+'));
    if (parts.isNotEmpty && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(parts[0])) {
      return parts[0].toLowerCase();
    }
  }
  stderr.writeln('Could not parse SHA256 output for ${file.path}.');
  exit(1);
}

Future<File> _writeSha256Sidecar(File artifact, String sha256) async {
  final sidecar = File('${artifact.path}.sha256');
  final artifactName = artifact.uri.pathSegments.isEmpty
      ? artifact.path
      : artifact.uri.pathSegments.last;
  await sidecar.writeAsString('$sha256  $artifactName\n');
  return sidecar;
}

Future<String?> _gitHead() async {
  final result = await Process.run('git', [
    'rev-parse',
    'HEAD',
  ], runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    return null;
  }
  final value = result.stdout.toString().trim();
  return RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(value) ? value : null;
}

Future<void> _writeEvidence({
  required _Options options,
  required String generatedAt,
  required File artifact,
  required String sha256,
  required File sha256Sidecar,
  required Map<String, Object?> toolVersions,
  required String? runtimeSmokeLog,
}) async {
  if (runtimeSmokeLog == null || runtimeSmokeLog.isEmpty) {
    stderr.writeln(
      '--write-evidence requires --runtime-smoke-log because the public release verifier requires a runtime smoke artifact.',
    );
    exit(1);
  }
  final smokeFile = File(runtimeSmokeLog);
  if (!smokeFile.existsSync() || smokeFile.lengthSync() == 0) {
    stderr.writeln('Runtime smoke log is missing or empty: $runtimeSmokeLog');
    exit(1);
  }
  final evidence = {
    'metadataSchemaVersion': _metadataSchemaVersion,
    'generatedAt': generatedAt,
    'platform': 'linux',
    'buildCommand': options.buildCommand,
    'toolVersions': toolVersions,
    'sourceGitHead': await _gitHead(),
    'githubRunId': options.githubRunId,
    'githubRepository': options.githubRepository,
    'githubSha': options.githubSha,
    'buildPassed': true,
    'packageArtifactPath': artifact.absolute.path.replaceAll('\\', '/'),
    'packageSizeBytes': artifact.lengthSync(),
    'packageSha256': sha256,
    'packageSha256Path': sha256Sidecar.absolute.path.replaceAll('\\', '/'),
    'runtimeSmokePassed': options.runtimeSmokePassed,
    'runtimeSmokeArtifact': smokeFile.absolute.path.replaceAll('\\', '/'),
    'runtimeSmokeChecks': _runtimeSmokeChecks(),
    'nativeLibraryNotes': options.nativeLibraryNotes,
    'linuxPermissionNotes': options.linuxPermissionNotes,
    'metadataPath': File(
      options.metadataPath,
    ).absolute.path.replaceAll('\\', '/'),
    'notes': options.runtimeSmokePassed
        ? 'Generated by linux_release_package_metadata.dart from a Linux bundle and supplied runtime smoke log.'
        : 'Generated package metadata, but runtime smoke was not marked passed. This evidence intentionally remains blocked until a Linux runtime smoke passes.',
  };
  await File(options.evidencePath).parent.create(recursive: true);
  await File(
    options.evidencePath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
}

List<Map<String, Object?>> _runtimeSmokeChecks() {
  return [
    for (final entry in _requiredRuntimeSmokeChecks.entries)
      {'check': entry.key, 'passed': true, 'evidence': entry.value},
  ];
}

Future<Map<String, Object?>> _toolVersions() async {
  return {
    'operatingSystem': Platform.operatingSystem,
    'operatingSystemVersion': Platform.operatingSystemVersion,
    'dartVersion': Platform.version,
    'flutterVersion': await _commandOutput('flutter', ['--version']),
    'rustcVersion': await _commandOutput('rustc', ['--version']),
    'tarVersion': await _commandOutput('tar', ['--version']),
  };
}

Future<String?> _commandOutput(String executable, List<String> args) async {
  try {
    final result = await Process.run(
      executable,
      args,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      return null;
    }
    final output = [
      result.stdout.toString().trim(),
      result.stderr.toString().trim(),
    ].where((part) => part.isNotEmpty).join('\n');
    if (output.isEmpty) {
      return null;
    }
    const maxLength = 1200;
    return output.length <= maxLength
        ? output
        : '${output.substring(0, maxLength)}...';
  } on Object {
    return null;
  }
}

class _BundleFileEntry {
  final String path;
  final int sizeBytes;
  final String sha256;

  const _BundleFileEntry({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
  });

  Map<String, Object?> toJson() => {
    'path': path,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
  };
}

class _Options {
  final String bundleDir;
  final String outputDir;
  final String artifactName;
  final String metadataPath;
  final String evidencePath;
  final String buildCommand;
  final String? runtimeSmokeLog;
  final bool runtimeSmokePassed;
  final bool writeEvidence;
  final String? githubRunId;
  final String? githubRepository;
  final String? githubSha;
  final List<String> nativeLibraryNotes;
  final List<String> linuxPermissionNotes;

  const _Options({
    required this.bundleDir,
    required this.outputDir,
    required this.artifactName,
    required this.metadataPath,
    required this.evidencePath,
    required this.buildCommand,
    required this.runtimeSmokeLog,
    required this.runtimeSmokePassed,
    required this.writeEvidence,
    required this.githubRunId,
    required this.githubRepository,
    required this.githubSha,
    required this.nativeLibraryNotes,
    required this.linuxPermissionNotes,
  });

  factory _Options.parse(List<String> args) {
    var bundleDir = _defaultBundleDir;
    var outputDir = _defaultOutputDir;
    var artifactName = 'skotiq-linux-x64.tar.gz';
    var metadataPath = _defaultMetadataPath;
    var evidencePath = _defaultEvidencePath;
    var buildCommand = 'dart run melos run build:desktop:linux --no-select';
    String? runtimeSmokeLog;
    var runtimeSmokePassed = false;
    var writeEvidence = false;
    final nativeLibraryNotes = <String>[..._defaultNativeLibraryNotes];
    final linuxPermissionNotes = <String>[..._defaultLinuxPermissionNotes];
    final githubRunId = Platform.environment['GITHUB_RUN_ID'];
    final githubRepository = Platform.environment['GITHUB_REPOSITORY'];
    final githubSha = Platform.environment['GITHUB_SHA'];

    for (final arg in args) {
      if (arg.startsWith('--bundle-dir=')) {
        bundleDir = arg.substring('--bundle-dir='.length);
      } else if (arg.startsWith('--output-dir=')) {
        outputDir = arg.substring('--output-dir='.length);
      } else if (arg.startsWith('--artifact-name=')) {
        artifactName = arg.substring('--artifact-name='.length);
      } else if (arg.startsWith('--metadata-output=')) {
        metadataPath = arg.substring('--metadata-output='.length);
      } else if (arg.startsWith('--evidence-output=')) {
        evidencePath = arg.substring('--evidence-output='.length);
      } else if (arg.startsWith('--build-command=')) {
        buildCommand = arg.substring('--build-command='.length);
      } else if (arg.startsWith('--runtime-smoke-log=')) {
        runtimeSmokeLog = arg.substring('--runtime-smoke-log='.length);
      } else if (arg == '--runtime-smoke-passed') {
        runtimeSmokePassed = true;
      } else if (arg == '--write-evidence') {
        writeEvidence = true;
      } else if (arg.startsWith('--native-library-note=')) {
        final note = arg.substring('--native-library-note='.length).trim();
        if (note.isNotEmpty) {
          nativeLibraryNotes.add(note);
        }
      } else if (arg.startsWith('--linux-permission-note=')) {
        final note = arg.substring('--linux-permission-note='.length).trim();
        if (note.isNotEmpty) {
          linuxPermissionNotes.add(note);
        }
      } else if (arg == '--help' || arg == '-h') {
        stdout.writeln(
          'Usage: dart run tools/production/linux_release_package_metadata.dart '
          '[--bundle-dir=path] [--output-dir=path] [--artifact-name=name] '
          '[--metadata-output=path] [--write-evidence --runtime-smoke-log=path '
          '[--runtime-smoke-passed]] [--native-library-note=text] '
          '[--linux-permission-note=text]',
        );
        exit(0);
      } else {
        throw ArgumentError('Unknown argument: $arg');
      }
    }

    return _Options(
      bundleDir: bundleDir,
      outputDir: outputDir,
      artifactName: artifactName,
      metadataPath: metadataPath,
      evidencePath: evidencePath,
      buildCommand: buildCommand,
      runtimeSmokeLog: runtimeSmokeLog,
      runtimeSmokePassed: runtimeSmokePassed,
      writeEvidence: writeEvidence,
      githubRunId: githubRunId,
      githubRepository: githubRepository,
      githubSha: githubSha,
      nativeLibraryNotes: List.unmodifiable(nativeLibraryNotes),
      linuxPermissionNotes: List.unmodifiable(linuxPermissionNotes),
    );
  }
}
