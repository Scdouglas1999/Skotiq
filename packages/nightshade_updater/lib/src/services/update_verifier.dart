import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as path;
import '../models/update_manifest.dart';

/// A trusted Ed25519 verification key paired with the id used to revoke it.
///
/// The id never enters the signed canonical payload — it exists only so the
/// build/operator can rotate (carry a `next` key alongside the `primary`
/// during a release window) and revoke (drop a key by id) without a wire
/// format change. Revocation is keyed on the key that actually verifies,
/// so a forged manifest-claimed id cannot redirect trust.
class _TrustedKey {
  final String keyId;
  final String base64;
  const _TrustedKey(this.keyId, this.base64);
}

/// Service for verifying update package integrity
class UpdateVerifier {
  final List<_TrustedKey> _trustedKeys;
  final Set<String> _revokedKeyIds;
  final Ed25519 _signatureAlgorithm;

  UpdateVerifier({
    String trustedPublicKeyBase64 = const String.fromEnvironment(
      'NIGHTSHADE_UPDATE_PUBLIC_KEY',
    ),
    String primaryKeyId = const String.fromEnvironment(
      'NIGHTSHADE_UPDATE_KEY_ID',
      defaultValue: 'primary',
    ),
    String nextTrustedPublicKeyBase64 = const String.fromEnvironment(
      'NIGHTSHADE_UPDATE_PUBLIC_KEY_NEXT',
    ),
    String nextKeyId = const String.fromEnvironment(
      'NIGHTSHADE_UPDATE_KEY_ID_NEXT',
      defaultValue: 'next',
    ),
    // Runtime-injectable revocation set, merged with the compile-time
    // NIGHTSHADE_UPDATE_REVOKED_KEY_IDS define so the wiring can later supply
    // a persisted roster without a rebuild.
    Set<String> revokedKeyIds = const {},
    Ed25519? signatureAlgorithm,
  }) : _signatureAlgorithm = signatureAlgorithm ?? Ed25519(),
       _revokedKeyIds = {..._parseRevokedDefine(), ...revokedKeyIds},
       _trustedKeys = [
         if (trustedPublicKeyBase64.isNotEmpty)
           _TrustedKey(primaryKeyId, trustedPublicKeyBase64),
         if (nextTrustedPublicKeyBase64.isNotEmpty)
           _TrustedKey(nextKeyId, nextTrustedPublicKeyBase64),
       ];

  static Set<String> _parseRevokedDefine() {
    const raw = String.fromEnvironment('NIGHTSHADE_UPDATE_REVOKED_KEY_IDS');
    if (raw.isEmpty) {
      return const {};
    }
    return raw
        .split(',')
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  /// Whether this verifier has at least one trusted Ed25519 public key that
  /// is compiled in and not revoked.
  ///
  /// Entry points like the LAN push receiver refuse to start when no key
  /// is available — without a key, signature verification cannot run and an
  /// attacker on the LAN could push an unsigned manifest. False here means
  /// "this build cannot authenticate any update; do not accept update
  /// bytes." Revoking every trusted key id drops this to false, which is
  /// the kill switch.
  bool get hasTrustedPublicKey =>
      _trustedKeys.any((key) => !_revokedKeyIds.contains(key.keyId));

  /// Calculate SHA256 hash of a file
  Future<String> hashFile(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// Calculate SHA256 hash of bytes
  String hashBytes(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  /// Verify a single file against expected hash
  Future<bool> verifyFile(File file, String expectedHash) async {
    if (!await file.exists()) {
      return false;
    }
    final actualHash = await hashFile(file);
    return actualHash.toLowerCase() == expectedHash.toLowerCase();
  }

  /// Verify all files in a directory against manifest
  Future<VerificationResult> verifyDirectory(
    Directory directory,
    UpdateManifest manifest,
  ) async {
    final missingFiles = <String>[];
    final corruptedFiles = <String, String>{};
    final verifiedFiles = <String>[];

    for (final entry in manifest.files.entries) {
      final relativePath = entry.key;
      final fileInfo = entry.value;
      final file = await _resolveManifestFile(directory, relativePath);
      if (file == null) {
        corruptedFiles[relativePath] = 'unsafe path';
        continue;
      }

      if (!await file.exists()) {
        missingFiles.add(relativePath);
        continue;
      }

      final actualHash = await hashFile(file);
      if (actualHash.toLowerCase() != fileInfo.sha256.toLowerCase()) {
        corruptedFiles[relativePath] = actualHash;
      } else {
        verifiedFiles.add(relativePath);
      }
    }

    return VerificationResult(
      success: missingFiles.isEmpty && corruptedFiles.isEmpty,
      verifiedFiles: verifiedFiles,
      missingFiles: missingFiles,
      corruptedFiles: corruptedFiles,
    );
  }

  Future<File?> _resolveManifestFile(
    Directory directory,
    String relativePath,
  ) async {
    final portablePath = relativePath.replaceAll('\\', '/');
    if (portablePath.isEmpty ||
        path.posix.isAbsolute(portablePath) ||
        RegExp(r'^[a-zA-Z]:/').hasMatch(portablePath) ||
        portablePath.startsWith('//')) {
      return null;
    }

    final normalized = path.posix.normalize(portablePath);
    if (normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        normalized.contains('/../') ||
        normalized.split('/').any((part) => part.isEmpty || part == '.')) {
      return null;
    }

    final root = await directory.resolveSymbolicLinks();
    final file = File(path.joinAll([root, ...normalized.split('/')]));
    if (await file.exists()) {
      final resolvedFile = await file.resolveSymbolicLinks();
      if (!_isWithinDirectory(root, resolvedFile)) {
        return null;
      }
    }
    return file;
  }

  bool _isWithinDirectory(String root, String candidate) {
    final normalizedRoot = _normalizeForComparison(path.normalize(root));
    final normalizedCandidate = _normalizeForComparison(
      path.normalize(candidate),
    );
    if (normalizedCandidate == normalizedRoot) {
      return true;
    }
    final rootWithSeparator = normalizedRoot.endsWith(path.separator)
        ? normalizedRoot
        : '$normalizedRoot${path.separator}';
    return normalizedCandidate.startsWith(rootWithSeparator);
  }

  String _normalizeForComparison(String value) {
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  /// Verify a downloaded package (ZIP file) before extraction
  Future<bool> verifyPackage(File packageFile, UpdateManifest manifest) async {
    if (!await packageFile.exists()) {
      return false;
    }

    // Check size
    final actualSize = await packageFile.length();
    if (actualSize != manifest.compressedSize) {
      return false;
    }

    if (manifest.packageSha256 == null || manifest.packageSha256!.isEmpty) {
      return false;
    }

    final actualHash = await hashFile(packageFile);
    if (actualHash.toLowerCase() != manifest.packageSha256!.toLowerCase()) {
      return false;
    }

    // Signature verification is MANDATORY for every staged update. A
    // correct SHA-256 only proves the bytes match the manifest as handed
    // over; it says nothing about whether that manifest came from the
    // vendor. A self-referential manifest (attacker-supplied package +
    // attacker-supplied matching hash) would otherwise pass on hash alone.
    // Hash agreement therefore never returns true on its own: the manifest
    // must carry an Ed25519 signature that verifies against the trusted key
    // compiled into this build. [verifyManifestSignature] returns false
    // when this build has no trusted key or the manifest is unsigned, so
    // both of those cases fail closed here, matching the LAN push receiver,
    // which refuses to start without a trusted key.
    return verifyManifestSignature(manifest);
  }

  Future<bool> verifyManifestSignature(UpdateManifest manifest) async =>
      await verifyingKeyId(manifest) != null;

  /// Return the id of the trusted, non-revoked key whose signature verifies
  /// this manifest, or null when none does. Trying every trusted key in turn
  /// supports rotation overlap (a manifest signed by either the outgoing
  /// `primary` or the incoming `next` key verifies during the window), while
  /// revocation is applied to the key that actually verifies — never to an
  /// id the manifest claims — so a forged id cannot redirect trust.
  Future<String?> verifyingKeyId(UpdateManifest manifest) async {
    if (manifest.signature == null || manifest.signature!.isEmpty) {
      return null;
    }
    for (final key in _trustedKeys) {
      if (_revokedKeyIds.contains(key.keyId)) {
        continue;
      }
      if (await _verifyWithKey(manifest, key.base64)) {
        return key.keyId;
      }
    }
    return null;
  }

  Future<bool> _verifyWithKey(
    UpdateManifest manifest,
    String publicKeyBase64,
  ) async {
    try {
      final payloadBytes = utf8.encode(canonicalManifestPayload(manifest));
      final publicKey = SimplePublicKey(
        base64Decode(publicKeyBase64),
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        base64Decode(manifest.signature!),
        publicKey: publicKey,
      );
      return await _signatureAlgorithm.verify(
        payloadBytes,
        signature: signature,
      );
    } catch (e) {
      developer.log(
        'Signature verification error: $e',
        name: 'UpdateVerifier',
        level: 900,
      );
      return false;
    }
  }

  /// Canonical byte payload that the vendor signs and this verifier checks.
  ///
  /// Exposed as a public static so the dev signing tool and the test suite
  /// build the exact same bytes instead of hand-copying this map (a live
  /// drift risk). The output MUST stay byte-identical to what
  /// `tool/build_update_manifest.dart` signs in production (every platform,
  /// Windows through `scripts/build_update_package.ps1`).
  static String canonicalManifestPayload(UpdateManifest manifest) {
    final sortedFiles = manifest.files.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final payload = <String, dynamic>{
      'version': manifest.version,
      'buildNumber': manifest.buildNumber,
      'releaseDate': manifest.releaseDate.toUtc().toIso8601String(),
      'platform': manifest.platform,
      'arch': manifest.arch,
      'minVersion': manifest.minVersion,
      'files': {
        for (final entry in sortedFiles)
          entry.key: {
            'path': entry.value.path,
            'size': entry.value.size,
            'sha256': entry.value.sha256,
          },
      },
      'totalSize': manifest.totalSize,
      'compressedSize': manifest.compressedSize,
      'packageSha256': manifest.packageSha256,
      'downloadUrl': manifest.downloadUrl,
      'releaseNotes': manifest.releaseNotes,
    };
    return jsonEncode(payload);
  }
}

/// Result of verifying a directory against a manifest
class VerificationResult {
  final bool success;
  final List<String> verifiedFiles;
  final List<String> missingFiles;
  final Map<String, String> corruptedFiles; // path -> actual hash

  VerificationResult({
    required this.success,
    required this.verifiedFiles,
    required this.missingFiles,
    required this.corruptedFiles,
  });

  @override
  String toString() {
    if (success) {
      return 'Verification successful: ${verifiedFiles.length} files verified';
    }
    final issues = <String>[];
    if (missingFiles.isNotEmpty) {
      issues.add('Missing: ${missingFiles.join(", ")}');
    }
    if (corruptedFiles.isNotEmpty) {
      issues.add('Corrupted: ${corruptedFiles.keys.join(", ")}');
    }
    return 'Verification failed: ${issues.join("; ")}';
  }
}
