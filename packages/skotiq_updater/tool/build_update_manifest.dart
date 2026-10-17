// Builds — and, when a signing key is present, signs — the OTA manifest that
// ships alongside a release.
//
// scripts/build_update_package.ps1 does this for Windows and cannot run
// anywhere else, which is why Linux and Android releases carried no manifest
// and so could never be discovered by the updater. This tool does the same job
// in Dart, on any platform, for both shapes of release:
//
//   * A directory of files the desktop updater swaps in (Windows, Linux).
//     The directory is zipped and every file is hashed into the manifest.
//   * A single APK that Android's package installer consumes. There is
//     nothing to zip and nothing to swap, so the APK is its own package.
//
// The signature covers UpdateVerifier.canonicalManifestPayload, built by the
// same code the runtime verifier uses, so a manifest signed here verifies
// under the exact path a shipped build runs.
//
// Usage:
//   dart run tool/build_update_manifest.dart \
//     --payload <dir|file.apk> --out-dir dist \
//     --version 7.2.0 --build-number 42 \
//     --platform linux --arch x64 \
//     --download-url https://github.com/<owner>/<repo>/releases/download/v7.2.0/<asset>
//
// SKOTIQ_UPDATE_PRIVATE_KEY (base64 Ed25519 seed) signs the manifest when
// set. Without it the manifest is written unsigned and the build still
// succeeds — an unsigned manifest is refused at download time, so OTA
// stays off rather than the release failing to build.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as p;

/// Oldest version that may update over the wire. Matches the value
/// build_update_package.ps1 has always written; anything older is told to
/// reinstall by hand instead.
const String _defaultMinVersion = '2.0.0';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);

  final payload = options['payload']!;
  final outDir = Directory(options['out-dir'] ?? 'dist');
  final version = options['version']!;
  final buildNumber = int.parse(options['build-number']!);
  final platform = options['platform']!;
  final arch = options['arch']!;
  final downloadUrl = options['download-url']!;
  final minVersion = options['min-version'] ?? _defaultMinVersion;
  final releaseNotes = options['release-notes'];
  final packageName = options['package-name'];

  await outDir.create(recursive: true);

  final entity = FileSystemEntity.typeSync(payload);
  final _PackagedRelease packaged;
  switch (entity) {
    case FileSystemEntityType.directory:
      packaged = await _packageDirectory(
        source: Directory(payload),
        outDir: outDir,
        packageName: packageName ?? 'skotiq-$version-$platform-$arch.zip',
      );
    case FileSystemEntityType.file:
      packaged = await _packageSingleFile(File(payload));
    default:
      stderr.writeln('No such payload: $payload');
      exit(1);
  }

  final manifest = UpdateManifest(
    version: version,
    buildNumber: buildNumber,
    // Second precision, UTC. The canonical payload re-serializes this, so a
    // value carrying sub-second precision would still sign and verify — but
    // it is compared against the anti-freeze watermark, and keeping the
    // resolution uniform across platforms keeps those comparisons readable.
    releaseDate: DateTime.now().toUtc().copyWith(
      millisecond: 0,
      microsecond: 0,
    ),
    platform: platform,
    arch: arch,
    minVersion: minVersion,
    files: packaged.files,
    totalSize: packaged.totalSize,
    compressedSize: packaged.compressedSize,
    packageSha256: packaged.packageSha256,
    downloadUrl: downloadUrl,
    releaseNotes: releaseNotes ?? 'Update to version $version',
  );

  final signed = await _sign(manifest);

  // Per-target name so one release can carry manifests for every platform it
  // builds. The publish job copies every artifact into one flat directory, so
  // a shared `manifest.json` would have each platform silently overwrite the
  // last and leave one arbitrary target's manifest standing.
  final manifestFile = File(
    p.join(outDir.path, 'manifest-$platform-$arch.json'),
  );
  await manifestFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(signed.toJson()),
  );

  stdout
    ..writeln('Wrote ${manifestFile.path}')
    ..writeln('  version:    $version+$buildNumber')
    ..writeln('  target:     $platform/$arch')
    ..writeln('  package:    ${packaged.packagePath}')
    ..writeln('  size:       ${packaged.compressedSize} bytes')
    ..writeln('  sha256:     ${packaged.packageSha256}')
    ..writeln('  files:      ${packaged.files.length}')
    ..writeln(
      '  signature:  ${signed.signature == null ? "UNSIGNED (OTA disabled)" : "present"}',
    );
}

/// Zip a build directory and hash every file inside it.
Future<_PackagedRelease> _packageDirectory({
  required Directory source,
  required Directory outDir,
  required String packageName,
}) async {
  if (!await source.exists()) {
    stderr.writeln('No such directory: ${source.path}');
    exit(1);
  }

  final files = <String, UpdateFileInfo>{};
  var totalSize = 0;

  // Sorted so the archive and the manifest are built in one fixed order,
  // which keeps two builds of identical inputs comparable.
  final entries = await source
      .list(recursive: true, followLinks: false)
      .toList();
  final regularFiles = entries.whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final encoder = ZipFileEncoder()..create(p.join(outDir.path, packageName));

  for (final file in regularFiles) {
    // POSIX separators in the manifest regardless of the host building it:
    // the verifier looks files up by this key on the target machine, and a
    // Windows-built manifest keyed with backslashes would miss every file on
    // a Linux host.
    final relative = p
        .relative(file.path, from: source.path)
        .replaceAll(r'\', '/');
    final bytes = await file.readAsBytes();
    files[relative] = UpdateFileInfo(
      path: relative,
      size: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
    totalSize += bytes.length;
    await encoder.addFile(file, relative);
  }

  await encoder.close();

  final packageFile = File(p.join(outDir.path, packageName));
  final packageBytes = await packageFile.readAsBytes();

  return _PackagedRelease(
    packagePath: packageFile.path,
    files: files,
    totalSize: totalSize,
    compressedSize: packageBytes.length,
    packageSha256: sha256.convert(packageBytes).toString(),
  );
}

/// Treat a single file (an APK) as its own package.
Future<_PackagedRelease> _packageSingleFile(File file) async {
  if (!await file.exists()) {
    stderr.writeln('No such file: ${file.path}');
    exit(1);
  }
  final bytes = await file.readAsBytes();
  final name = p.basename(file.path);
  final digest = sha256.convert(bytes).toString();

  return _PackagedRelease(
    packagePath: file.path,
    // One entry, so the manifest still describes what it is delivering.
    // Nothing on Android walks this map — the installer takes the whole file
    // — but leaving it empty would make the manifest silently contentless.
    files: {
      name: UpdateFileInfo(path: name, size: bytes.length, sha256: digest),
    },
    totalSize: bytes.length,
    compressedSize: bytes.length,
    packageSha256: digest,
  );
}

/// Sign the manifest when a key is provisioned, else return it unsigned.
Future<UpdateManifest> _sign(UpdateManifest manifest) async {
  final seedBase64 = Platform.environment['SKOTIQ_UPDATE_PRIVATE_KEY']
      ?.trim();
  if (seedBase64 == null || seedBase64.isEmpty) {
    stderr.writeln(
      'SKOTIQ_UPDATE_PRIVATE_KEY is not set: writing an UNSIGNED '
      'manifest. Builds will refuse to install this update.',
    );
    return manifest;
  }

  final seed = base64Decode(seedBase64);
  if (seed.length != 32) {
    stderr.writeln(
      'SKOTIQ_UPDATE_PRIVATE_KEY must be a 32-byte Ed25519 seed, got '
      '${seed.length} bytes.',
    );
    exit(1);
  }

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final signature = await algorithm.sign(
    utf8.encode(UpdateVerifier.canonicalManifestPayload(manifest)),
    keyPair: keyPair,
  );
  return manifest.copyWith(signature: base64Encode(signature.bytes));
}

class _PackagedRelease {
  final String packagePath;
  final Map<String, UpdateFileInfo> files;
  final int totalSize;
  final int compressedSize;
  final String packageSha256;

  _PackagedRelease({
    required this.packagePath,
    required this.files,
    required this.totalSize,
    required this.compressedSize,
    required this.packageSha256,
  });
}

const _required = {
  'payload',
  'version',
  'build-number',
  'platform',
  'arch',
  'download-url',
};

Map<String, String> _parseArgs(List<String> args) {
  final parsed = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      stderr.writeln('Unexpected argument: $arg');
      exit(64);
    }
    final key = arg.substring(2);
    if (i + 1 >= args.length) {
      stderr.writeln('Option --$key needs a value.');
      exit(64);
    }
    parsed[key] = args[++i];
  }

  final missing = _required.where((k) => parsed[k] == null).toList()..sort();
  if (missing.isNotEmpty) {
    stderr.writeln('Missing required options: ${missing.join(', ')}');
    exit(64);
  }
  return parsed;
}
