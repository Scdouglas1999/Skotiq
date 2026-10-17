/// The per-job delivery manifest a rig publishes and a paired desktop pulls.
///
/// The manifest is the whole peer protocol: it names every file the job
/// published for one peer, with the size and the SHA-256 the rig computed. The
/// desktop pulls each entry by its opaque id and verifies the bytes against
/// the checksum here, so a truncated or substituted download is caught by the
/// puller rather than by the operator opening a corrupt master weeks later.
///
/// **Ids are opaque on purpose.** An entry is addressed by the SHA-256 of its
/// path on the rig, never by the path itself: the download endpoint resolves
/// an id back to a published row, so no request can name a file the job did
/// not publish.
///
/// **Signing.** The signature binds the checksums to the principal that asked
/// for the manifest. The key is derived from the authenticated caller's token
/// digest — the same `computeServerFingerprint` value the server already
/// carries on the request context — so the desktop, which knows its own token,
/// can verify without any new key distribution, and the raw token stays out of
/// the handler entirely. A manifest served on a server with no token
/// configured carries no signature and says so.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Wire version of the manifest document. A desktop that does not recognise
/// the version refuses the manifest rather than guessing at the fields.
const int kDeliveryManifestVersion = 1;

/// Domain separator for the manifest signing key, so the derived key cannot
/// be reused as, or confused with, any other use of the same token digest.
const String kDeliveryManifestSigningContext =
    'skotiq.delivery.manifest.v1';

/// Algorithm name written into the signature envelope.
const String kDeliveryManifestSignatureAlgorithm = 'hmac-sha256-token-v1';

/// A manifest document did not parse, or claims a version this build does not
/// implement.
class DeliveryManifestFormatException implements Exception {
  /// What is wrong with the document.
  final String message;

  const DeliveryManifestFormatException(this.message);

  @override
  String toString() => 'DeliveryManifestFormatException: $message';
}

/// One published file in a manifest.
class DeliveryManifestEntry {
  /// Opaque id the download endpoint resolves. SHA-256 of the rig-side path.
  final String artifactId;

  /// The `delivery_targets.id` this file was published for. The desktop
  /// echoes it back when acknowledging, so the right destination's journal row
  /// is the one that records the arrival.
  final int targetId;

  /// The name the desktop writes.
  final String fileName;

  /// Size in bytes on the rig.
  final int bytes;

  /// Lowercase hex SHA-256 of the bytes on the rig.
  final String checksum;

  const DeliveryManifestEntry({
    required this.artifactId,
    required this.targetId,
    required this.fileName,
    required this.bytes,
    required this.checksum,
  });

  /// The wire object, with keys in a fixed order.
  Map<String, Object?> toJson() => <String, Object?>{
    'artifactId': artifactId,
    'bytes': bytes,
    'checksum': checksum,
    'fileName': fileName,
    'targetId': targetId,
  };

  /// Parse one wire object.
  static DeliveryManifestEntry fromJson(Object? value) {
    if (value is! Map) {
      throw const DeliveryManifestFormatException(
        'a manifest entry is not a JSON object',
      );
    }
    return DeliveryManifestEntry(
      artifactId: _requireString(value, 'artifactId'),
      targetId: _requireInt(value, 'targetId'),
      fileName: _requireString(value, 'fileName'),
      bytes: _requireInt(value, 'bytes'),
      checksum: _requireString(value, 'checksum'),
    );
  }
}

/// A file this job published that the rig cannot serve right now.
///
/// Stating the absence is the point. A manifest that simply omitted the file
/// would read as a job that produced less than it did, and the desktop would
/// report a complete pull of an incomplete night.
class UnavailableArtifact {
  /// Opaque id of the file that cannot be served.
  final String artifactId;

  /// Why it cannot be served, in the rig's words.
  final String reason;

  const UnavailableArtifact({required this.artifactId, required this.reason});

  /// The wire object, with keys in a fixed order.
  Map<String, Object?> toJson() => <String, Object?>{
    'artifactId': artifactId,
    'reason': reason,
  };

  /// Parse one wire object.
  static UnavailableArtifact fromJson(Object? value) {
    if (value is! Map) {
      throw const DeliveryManifestFormatException(
        'an unavailable-artifact record is not a JSON object',
      );
    }
    return UnavailableArtifact(
      artifactId: _requireString(value, 'artifactId'),
      reason: _requireString(value, 'reason'),
    );
  }
}

/// Everything one job published for one peer.
class DeliveryManifest {
  /// Wire version of this document.
  final int version;

  /// The `darkroom_jobs.id` the artifacts came from.
  final int jobId;

  /// The peer identity this manifest was built for.
  final String peerId;

  /// When the rig built the document.
  final DateTime generatedAt;

  /// The published files, ordered by [DeliveryManifestEntry.artifactId] so two
  /// builds of the same publication produce the same bytes.
  final List<DeliveryManifestEntry> entries;

  /// Files this job published that the rig cannot serve right now, in the same
  /// id order.
  final List<UnavailableArtifact> unavailable;

  DeliveryManifest({
    required this.jobId,
    required this.peerId,
    required this.generatedAt,
    required List<DeliveryManifestEntry> entries,
    List<UnavailableArtifact> unavailable = const [],
    this.version = kDeliveryManifestVersion,
  }) : entries = (List<DeliveryManifestEntry>.from(entries)
         ..sort((a, b) => a.artifactId.compareTo(b.artifactId))),
       unavailable = (List<UnavailableArtifact>.from(unavailable)
         ..sort((a, b) => a.artifactId.compareTo(b.artifactId)));

  /// Total bytes the desktop is about to pull.
  int get totalBytes => entries.fold<int>(0, (sum, e) => sum + e.bytes);

  /// The wire object.
  Map<String, Object?> toJson() => <String, Object?>{
    'entries': entries.map((e) => e.toJson()).toList(growable: false),
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'jobId': jobId,
    'peerId': peerId,
    'unavailable': unavailable.map((e) => e.toJson()).toList(growable: false),
    'version': version,
  };

  /// Parse a manifest document.
  static DeliveryManifest fromJson(Object? value) {
    if (value is! Map) {
      throw const DeliveryManifestFormatException(
        'the manifest is not a JSON object',
      );
    }
    final version = _requireInt(value, 'version');
    if (version != kDeliveryManifestVersion) {
      throw DeliveryManifestFormatException(
        'the manifest is version $version and this build reads version '
        '$kDeliveryManifestVersion',
      );
    }
    final rawEntries = value['entries'];
    if (rawEntries is! List) {
      throw const DeliveryManifestFormatException(
        'the manifest carries no entries array',
      );
    }
    final generatedAt = DateTime.tryParse(_requireString(value, 'generatedAt'));
    if (generatedAt == null) {
      throw const DeliveryManifestFormatException(
        'the manifest\'s generatedAt is not a timestamp',
      );
    }
    final rawUnavailable = value['unavailable'];
    if (rawUnavailable is! List) {
      throw const DeliveryManifestFormatException(
        'the manifest carries no unavailable array',
      );
    }
    return DeliveryManifest(
      version: version,
      jobId: _requireInt(value, 'jobId'),
      peerId: _requireString(value, 'peerId'),
      generatedAt: generatedAt,
      entries: rawEntries.map(DeliveryManifestEntry.fromJson).toList(),
      unavailable: rawUnavailable.map(UnavailableArtifact.fromJson).toList(),
    );
  }
}

/// A manifest plus the signature over it, or the reason there is none.
class SignedDeliveryManifest {
  /// The document.
  final DeliveryManifest manifest;

  /// Hex HMAC over the manifest's canonical bytes, or null when the server
  /// had no authenticated principal to derive a key from.
  final String? signature;

  /// Why [signature] is null. Null when there is a signature.
  final String? signatureAbsentReason;

  const SignedDeliveryManifest({
    required this.manifest,
    this.signature,
    this.signatureAbsentReason,
  });

  /// Sign [manifest] for the principal identified by [authIdentity].
  factory SignedDeliveryManifest.sign({
    required DeliveryManifest manifest,
    required String authIdentity,
  }) {
    return SignedDeliveryManifest(
      manifest: manifest,
      signature: deliveryManifestSignature(
        manifest: manifest,
        authIdentity: authIdentity,
      ),
    );
  }

  /// Publish [manifest] without a signature, stating why.
  factory SignedDeliveryManifest.unsigned({
    required DeliveryManifest manifest,
    required String reason,
  }) {
    return SignedDeliveryManifest(
      manifest: manifest,
      signatureAbsentReason: reason,
    );
  }

  /// The wire envelope.
  Map<String, Object?> toJson() => <String, Object?>{
    'manifest': manifest.toJson(),
    'signature': signature == null
        ? null
        : <String, Object?>{
            'algorithm': kDeliveryManifestSignatureAlgorithm,
            'value': signature,
          },
    if (signatureAbsentReason != null)
      'signatureAbsentReason': signatureAbsentReason,
  };

  /// Parse a wire envelope.
  static SignedDeliveryManifest fromJson(Object? value) {
    if (value is! Map) {
      throw const DeliveryManifestFormatException(
        'the manifest envelope is not a JSON object',
      );
    }
    final signature = value['signature'];
    String? signatureValue;
    if (signature != null) {
      if (signature is! Map) {
        throw const DeliveryManifestFormatException(
          'the manifest signature is not a JSON object',
        );
      }
      final algorithm = signature['algorithm'];
      if (algorithm != kDeliveryManifestSignatureAlgorithm) {
        throw DeliveryManifestFormatException(
          'the manifest is signed with $algorithm and this build verifies '
          '$kDeliveryManifestSignatureAlgorithm',
        );
      }
      signatureValue = _requireString(signature, 'value');
    }
    final reason = value['signatureAbsentReason'];
    return SignedDeliveryManifest(
      manifest: DeliveryManifest.fromJson(value['manifest']),
      signature: signatureValue,
      signatureAbsentReason: reason is String ? reason : null,
    );
  }

  /// Whether [signature] is the one [authIdentity] would produce over this
  /// manifest.
  ///
  /// Returns false when there is no signature: an unsigned manifest is not
  /// verified, and a caller that requires verification must refuse it rather
  /// than read [signatureAbsentReason] as an excuse.
  bool verify(String authIdentity) {
    final actual = signature;
    if (actual == null) return false;
    final expected = deliveryManifestSignature(
      manifest: manifest,
      authIdentity: authIdentity,
    );
    return _constantTimeEquals(expected, actual);
  }
}

/// The canonical bytes a manifest signature covers.
///
/// Keys are sorted recursively before encoding, so the signature survives a
/// round trip through any JSON implementation that does not preserve document
/// order.
List<int> canonicalManifestBytes(DeliveryManifest manifest) =>
    utf8.encode(jsonEncode(_canonicalize(manifest.toJson())));

/// Hex HMAC-SHA256 over [manifest]'s canonical bytes under the key derived
/// from [authIdentity].
String deliveryManifestSignature({
  required DeliveryManifest manifest,
  required String authIdentity,
}) {
  if (authIdentity.isEmpty) {
    throw ArgumentError.value(
      authIdentity,
      'authIdentity',
      'a manifest cannot be signed without an authenticated principal',
    );
  }
  final signingKey = Hmac(
    sha256,
    utf8.encode(authIdentity),
  ).convert(utf8.encode(kDeliveryManifestSigningContext)).bytes;
  return Hmac(
    sha256,
    signingKey,
  ).convert(canonicalManifestBytes(manifest)).toString();
}

/// The opaque manifest id for the artifact stored at [sourcePath] on the rig.
String artifactIdForPath(String sourcePath) =>
    sha256.convert(utf8.encode(sourcePath)).toString();

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalize).toList(growable: false);
  return value;
}

/// Compare two hex digests without an early return on the first differing
/// character.
bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

String _requireString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw DeliveryManifestFormatException(
      'the manifest field "$key" is not a non-empty string',
    );
  }
  return value;
}

int _requireInt(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! int) {
    throw DeliveryManifestFormatException(
      'the manifest field "$key" is not a whole number',
    );
  }
  return value;
}
