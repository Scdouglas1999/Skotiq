// The peer manifest is the whole pull protocol, so its wire form and its
// signature are pinned here: a round trip must survive key reordering, and a
// signature must fail for anything the manifest did not say.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_manifest.dart';

DeliveryManifest _manifest({
  int jobId = 7,
  String peerId = 'office-pc',
  List<DeliveryManifestEntry>? entries,
  List<UnavailableArtifact> unavailable = const [],
}) {
  return DeliveryManifest(
    jobId: jobId,
    peerId: peerId,
    generatedAt: DateTime.utc(2026, 8, 16, 6, 12, 30),
    entries:
        entries ??
        <DeliveryManifestEntry>[
          DeliveryManifestEntry(
            artifactId: 'ff' * 32,
            targetId: 3,
            fileName: 'M31_Ha_master.fits',
            bytes: 4096,
            checksum: 'ab' * 32,
          ),
          DeliveryManifestEntry(
            artifactId: '00' * 32,
            targetId: 3,
            fileName: 'draft.jpg',
            bytes: 512,
            checksum: 'cd' * 32,
          ),
        ],
    unavailable: unavailable,
  );
}

void main() {
  group('DeliveryManifest wire form', () {
    test('round-trips through JSON with every field intact', () {
      final original = _manifest(
        unavailable: [
          UnavailableArtifact(
            artifactId: '11' * 32,
            reason: 'sourceMissing: the job produced it but it is gone',
          ),
        ],
      );

      final parsed = DeliveryManifest.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      );

      expect(parsed.jobId, original.jobId);
      expect(parsed.peerId, original.peerId);
      expect(parsed.generatedAt, original.generatedAt);
      expect(parsed.entries.length, 2);
      expect(parsed.entries.first.fileName, 'draft.jpg');
      expect(parsed.totalBytes, 4608);
      expect(parsed.unavailable.single.artifactId, '11' * 32);
      expect(
        parsed.unavailable.single.reason,
        contains('the job produced it but it is gone'),
      );
    });

    test('orders entries by id so two builds produce the same bytes', () {
      final forward = _manifest();
      final reversed = _manifest(
        entries: _manifest().entries.reversed.toList(),
      );

      expect(
        jsonEncode(forward.toJson()),
        jsonEncode(reversed.toJson()),
        reason: 'entry order is derived, not taken from the caller',
      );
    });

    test('refuses a document from a version this build does not read', () {
      final wire = _manifest().toJson()..['version'] = 99;

      expect(
        () => DeliveryManifest.fromJson(wire),
        throwsA(isA<DeliveryManifestFormatException>()),
      );
    });

    test('refuses a document whose entries are not a list', () {
      final wire = _manifest().toJson()..['entries'] = 'four files';

      expect(
        () => DeliveryManifest.fromJson(wire),
        throwsA(isA<DeliveryManifestFormatException>()),
      );
    });

    test('refuses an entry missing its checksum', () {
      final wire = _manifest().toJson();
      ((wire['entries'] as List).first as Map<String, Object?>).remove(
        'checksum',
      );

      expect(
        () => DeliveryManifest.fromJson(wire),
        throwsA(isA<DeliveryManifestFormatException>()),
      );
    });
  });

  group('manifest signature', () {
    final identity = 'a3f1c0de' * 8;

    test('verifies for the principal that signed it', () {
      final signed = SignedDeliveryManifest.sign(
        manifest: _manifest(),
        authIdentity: identity,
      );

      expect(signed.verify(identity), isTrue);
    });

    test('survives a round trip through the wire envelope', () {
      final signed = SignedDeliveryManifest.sign(
        manifest: _manifest(),
        authIdentity: identity,
      );

      final parsed = SignedDeliveryManifest.fromJson(
        jsonDecode(jsonEncode(signed.toJson())),
      );

      expect(parsed.signature, signed.signature);
      expect(parsed.verify(identity), isTrue);
    });

    test('survives a re-encode that reorders the object keys', () {
      final signed = SignedDeliveryManifest.sign(
        manifest: _manifest(),
        authIdentity: identity,
      );
      final envelope =
          jsonDecode(jsonEncode(signed.toJson())) as Map<String, Object?>;
      final manifest = envelope['manifest'] as Map<String, Object?>;
      final shuffled = <String, Object?>{
        for (final key in manifest.keys.toList().reversed) key: manifest[key],
      };

      final parsed = SignedDeliveryManifest.fromJson(<String, Object?>{
        ...envelope,
        'manifest': shuffled,
      });

      expect(
        parsed.verify(identity),
        isTrue,
        reason: 'the signature covers canonical bytes, not document order',
      );
    });

    test('fails for a different principal', () {
      final signed = SignedDeliveryManifest.sign(
        manifest: _manifest(),
        authIdentity: identity,
      );

      expect(signed.verify('b' * 64), isFalse);
    });

    test('fails when a checksum is edited in flight', () {
      final signed = SignedDeliveryManifest.sign(
        manifest: _manifest(),
        authIdentity: identity,
      );
      final envelope = signed.toJson();
      final manifest = envelope['manifest'] as Map<String, Object?>;
      final entries = manifest['entries'] as List;
      (entries.first as Map<String, Object?>)['checksum'] = '99' * 32;

      final tampered = SignedDeliveryManifest.fromJson(envelope);

      expect(tampered.verify(identity), isFalse);
    });

    test('an unsigned manifest never verifies, whatever its reason says', () {
      final unsigned = SignedDeliveryManifest.unsigned(
        manifest: _manifest(),
        reason: 'this server authenticated no principal',
      );

      expect(unsigned.signature, isNull);
      expect(unsigned.signatureAbsentReason, isNotNull);
      expect(unsigned.verify(identity), isFalse);
    });

    test('refuses an envelope signed with an algorithm this build cannot '
        'check', () {
      final envelope = SignedDeliveryManifest.sign(
        manifest: _manifest(),
        authIdentity: identity,
      ).toJson();
      (envelope['signature'] as Map<String, Object?>)['algorithm'] = 'md5-v0';

      expect(
        () => SignedDeliveryManifest.fromJson(envelope),
        throwsA(isA<DeliveryManifestFormatException>()),
      );
    });

    test('signing without a principal is refused rather than keyed on an '
        'empty string', () {
      expect(
        () =>
            deliveryManifestSignature(manifest: _manifest(), authIdentity: ''),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('artifact ids', () {
    test('are a stable digest of the rig-side path', () {
      expect(
        artifactIdForPath('/data/masters/M31.fits'),
        artifactIdForPath('/data/masters/M31.fits'),
      );
      expect(artifactIdForPath('/data/masters/M31.fits').length, 64);
    });

    test('differ for different paths, so one id names one file', () {
      expect(
        artifactIdForPath('/data/masters/M31.fits'),
        isNot(artifactIdForPath('/data/masters/M32.fits')),
      );
    });

    test('carry no path text, so an id cannot be walked', () {
      expect(
        artifactIdForPath('/data/../etc/passwd'),
        matches(r'^[0-9a-f]{64}$'),
      );
    });
  });
}
