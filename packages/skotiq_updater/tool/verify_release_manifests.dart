// Checks every OTA manifest a release is about to publish, with the code the
// shipped app runs, before anything is published.
//
// A release can be built, signed and published and still be one that no
// installed build will ever accept: the private key in CI not matching the
// public key compiled into the apps, the Windows packager's hand-copied signing
// payload drifting from UpdateVerifier's, a manifest naming a package that is
// not the one attached, or a download URL that does not point at it. Each of
// those shows up only on the operator's machine, and the first time it happens
// after the key is provisioned the only fix is a manual reinstall everywhere.
//
// Usage (from the package root):
//   SKOTIQ_UPDATE_PUBLIC_KEY=<base64> \
//   dart run tool/verify_release_manifests.dart --assets <dir> --tag v7.2.0 \
//     [--repo owner/name] [--require-signed]
//
// Exit 0 when every manifest checks out. Unsigned manifests are reported and
// accepted unless --require-signed is given (CI passes it once a private key
// is configured, so an unsigned release cannot slip out after that).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  final flags = <String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--require-signed') {
      flags.add('require-signed');
    } else if (arg.startsWith('--') && i + 1 < args.length) {
      options[arg.substring(2)] = args[++i];
    } else {
      stderr.writeln('Unexpected argument: $arg');
      exit(64);
    }
  }
  final assetsDir = options['assets'];
  final tag = options['tag'];
  if (assetsDir == null || tag == null) {
    stderr.writeln(
      'Usage: --assets <dir> --tag <vX.Y.Z> [--repo o/r] '
      '[--require-signed]',
    );
    exit(64);
  }
  final publicKey =
      Platform.environment['SKOTIQ_UPDATE_PUBLIC_KEY']?.trim() ?? '';

  final problems = await verifyReleaseManifests(
    assetsDir: Directory(assetsDir),
    tag: tag,
    repo: options['repo'],
    publicKeyBase64: publicKey,
    requireSigned: flags.contains('require-signed'),
    log: stdout.writeln,
  );
  if (problems.isEmpty) {
    stdout.writeln('All update manifests verify.');
    return;
  }
  for (final problem in problems) {
    stderr.writeln('::error::$problem');
  }
  exit(1);
}

/// Every reason the manifests in [assetsDir] would be refused by a shipped
/// build, or would install something other than what was attached. Empty
/// means the release is installable.
Future<List<String>> verifyReleaseManifests({
  required Directory assetsDir,
  required String tag,
  required String publicKeyBase64,
  String? repo,
  bool requireSigned = false,
  void Function(String)? log,
}) async {
  final problems = <String>[];
  final manifests =
      assetsDir
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                RegExp(r'^manifest(-.+)?\.json$').hasMatch(p.basename(f.path)),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (manifests.isEmpty) {
    return ['No update manifest in ${assetsDir.path}.'];
  }

  final verifier = UpdateVerifier(trustedPublicKeyBase64: publicKeyBase64);
  final version = tag.startsWith('v') ? tag.substring(1) : tag;

  for (final file in manifests) {
    final name = p.basename(file.path);
    final UpdateManifest manifest;
    try {
      manifest = UpdateManifest.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (e) {
      problems.add('$name is not a readable update manifest: $e');
      continue;
    }

    final target = 'manifest-${manifest.platform}-${manifest.arch}.json';
    if (name != 'manifest.json' && name != target) {
      problems.add(
        '$name describes ${manifest.platform}/${manifest.arch}; '
        'a shipped build looks for it under $target.',
      );
    }
    if (manifest.version != version) {
      problems.add(
        '$name is for version ${manifest.version}, but the '
        'release is $tag.',
      );
    }

    final unsigned = manifest.signature == null || manifest.signature!.isEmpty;
    if (unsigned) {
      if (requireSigned) {
        problems.add('$name is unsigned, but a signing key is configured.');
      } else {
        log?.call('$name: unsigned (every build will refuse it).');
      }
    } else if (publicKeyBase64.isEmpty) {
      problems.add(
        '$name is signed, but SKOTIQ_UPDATE_PUBLIC_KEY is '
        'empty, so the apps in this release cannot verify any update.',
      );
    } else if (!await verifier.verifyManifestSignature(manifest)) {
      problems.add(
        '$name does not verify against '
        'SKOTIQ_UPDATE_PUBLIC_KEY: the signing key and the public key '
        'compiled into the apps are not a pair, or the payload the packager '
        'signed differs from UpdateVerifier.canonicalManifestPayload.',
      );
    }

    final assetName = Uri.parse(manifest.downloadUrl).pathSegments.last;
    final expectedUrl = repo == null
        ? null
        : 'https://github.com/$repo/releases/download/$tag/$assetName';
    if (expectedUrl != null && manifest.downloadUrl != expectedUrl) {
      problems.add(
        '$name downloads ${manifest.downloadUrl}, not this '
        "release's asset $expectedUrl.",
      );
    }
    final package = File(p.join(assetsDir.path, assetName));
    if (!await package.exists()) {
      problems.add(
        '$name names $assetName, which is not among the release '
        'assets.',
      );
      continue;
    }
    final size = await package.length();
    if (size != manifest.compressedSize) {
      problems.add(
        '$name says $assetName is ${manifest.compressedSize} '
        'bytes; the attached file is $size.',
      );
    }
    final digest = sha256.convert(await package.readAsBytes()).toString();
    if (digest != manifest.packageSha256?.toLowerCase()) {
      problems.add(
        '$name hash for $assetName does not match the attached '
        'file.',
      );
    }
    log?.call(
      '$name: ${manifest.version}+${manifest.buildNumber} '
      '${manifest.platform}/${manifest.arch} -> $assetName '
      '(${unsigned ? "unsigned" : "signature checked"}).',
    );
  }
  return problems;
}
