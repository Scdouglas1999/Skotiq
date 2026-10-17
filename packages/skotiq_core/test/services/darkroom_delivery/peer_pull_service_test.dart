// The paired desktop's scheduled pull. The manifest signature is the thing
// that makes the checksums trustworthy, so a manifest that does not verify
// stops the pull before a single byte is requested.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_manifest.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/peer_pull_service.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/resumable_artifact_downloader.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show computeServerFingerprint;
import 'package:path/path.dart' as p;

/// A rig that answers manifest, artifact and acknowledgement requests out of
/// an in-memory publication.
class _FakeRig implements ArtifactHttpClient {
  _FakeRig({
    required this.token,
    required this.peerId,
    required this.files,
    this.signManifest = true,
    this.signAs,
  });

  final String token;
  final String peerId;

  /// fileName -> bytes.
  final Map<String, List<int>> files;
  final bool signManifest;
  final String? signAs;

  final List<Uri> gets = [];
  final List<Object?> acks = [];
  int closes = 0;

  Map<String, String> get _idsByName => {
    for (final name in files.keys) name: artifactIdForPath('/rig/$name'),
  };

  DeliveryManifest get manifest => DeliveryManifest(
    jobId: 7,
    peerId: peerId,
    generatedAt: DateTime.utc(2026, 8, 16, 6),
    entries: [
      for (final entry in files.entries)
        DeliveryManifestEntry(
          artifactId: _idsByName[entry.key]!,
          targetId: 3,
          fileName: entry.key,
          bytes: entry.value.length,
          checksum: sha256.convert(entry.value).toString(),
        ),
    ],
  );

  @override
  Future<ArtifactHttpResponse> get(Uri url, Map<String, String> headers) async {
    gets.add(url);
    if (headers['authorization'] != 'Bearer $token') {
      return _json(401, {'error': 'Unauthorized'});
    }
    if (url.path.contains('/manifest/')) {
      final signed = signManifest
          ? SignedDeliveryManifest.sign(
              manifest: manifest,
              authIdentity: computeServerFingerprint(signAs ?? token),
            )
          : SignedDeliveryManifest.unsigned(
              manifest: manifest,
              reason: 'this server authenticated no principal',
            );
      return _json(200, signed.toJson());
    }
    final artifactId = url.pathSegments.last;
    final name = _idsByName.entries
        .where((e) => e.value == artifactId)
        .map((e) => e.key)
        .firstOrNull;
    if (name == null) return _json(404, {'error': 'artifact_not_published'});
    final bytes = files[name]!;
    return ArtifactHttpResponse(
      statusCode: 200,
      headers: {'etag': '"$artifactId-1"', 'accept-ranges': 'bytes'},
      body: Stream<List<int>>.fromIterable([bytes]),
      contentLength: bytes.length,
    );
  }

  @override
  Future<ArtifactHttpResponse> postJson(
    Uri url,
    Map<String, String> headers,
    Object? body,
  ) async {
    acks.add(body);
    return _json(200, {'state': 'delivered'});
  }

  @override
  void close() => closes++;

  ArtifactHttpResponse _json(int status, Object? body) {
    final bytes = utf8.encode(jsonEncode(body));
    return ArtifactHttpResponse(
      statusCode: status,
      headers: const {'content-type': 'application/json'},
      body: Stream<List<int>>.fromIterable([bytes]),
      contentLength: bytes.length,
    );
  }
}

void main() {
  late Directory tempDir;
  const token = 'pairing-token-for-office-pc';
  const peerId = 'office-pc';
  final files = <String, List<int>>{
    'M31_Ha_master.fits': utf8.encode('HA-MASTER-BYTES'),
    'draft.jpg': utf8.encode('JPEG-BYTES'),
  };

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_peer_pull_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  PeerPullService serviceFor(
    ArtifactHttpClient rig, {
    String withToken = token,
  }) {
    return PeerPullService(
      baseUrl: Uri.parse('http://rig.local:8080'),
      token: withToken,
      peerId: peerId,
      destinationDirectory: Directory(p.join(tempDir.path, 'incoming')),
      http: rig,
    );
  }

  test(
    'pulls every published file, verifies it, and acknowledges it',
    () async {
      final rig = _FakeRig(token: token, peerId: peerId, files: files);

      final report = await serviceFor(rig).pullJob(7);

      expect(report.manifestProblem, isNull);
      expect(report.pulled, 2);
      expect(report.failed, 0);
      expect(report.complete, isTrue);
      for (final entry in files.entries) {
        final landed = File(p.join(tempDir.path, 'incoming', entry.key));
        expect(await landed.readAsBytes(), entry.value);
      }
      expect(rig.acks.length, 2);
      expect(
        (rig.acks.first as Map)['peerId'],
        peerId,
        reason: 'the rig needs to know which destination row to close',
      );
    },
  );

  test('asks for the manifest as the peer it is configured as', () async {
    final rig = _FakeRig(token: token, peerId: peerId, files: files);

    await serviceFor(rig).pullJob(7);

    expect(rig.gets.first.path, '/api/darkroom/delivery/manifest/7');
    expect(rig.gets.first.queryParameters['peer'], peerId);
  });

  test(
    'refuses a manifest signed for another pairing and downloads nothing',
    () async {
      final rig = _FakeRig(
        token: token,
        peerId: peerId,
        files: files,
        signAs: 'a-different-pairing-token',
      );

      final report = await serviceFor(rig).pullJob(7);

      expect(report.manifestProblem, contains('refused'));
      expect(report.pulled, 0);
      expect(
        rig.gets.length,
        1,
        reason: 'nothing was fetched after the refusal',
      );
      expect(Directory(p.join(tempDir.path, 'incoming')).existsSync(), isFalse);
    },
  );

  test('refuses an unsigned manifest and says why the rig gave', () async {
    final rig = _FakeRig(
      token: token,
      peerId: peerId,
      files: files,
      signManifest: false,
    );

    final report = await serviceFor(rig).pullJob(7);

    expect(report.manifestProblem, contains('authenticated no principal'));
    expect(report.pulled, 0);
  });

  test('a rejected token is reported, not retried into a loop', () async {
    final rig = _FakeRig(token: token, peerId: peerId, files: files);

    final report = await serviceFor(rig, withToken: 'stale-token').pullJob(7);

    expect(report.manifestProblem, contains('401'));
    expect(report.pulled, 0);
  });

  test('a file already here with the published checksum is acknowledged, not '
      'fetched again', () async {
    final incoming = await Directory(
      p.join(tempDir.path, 'incoming'),
    ).create(recursive: true);
    await File(
      p.join(incoming.path, 'draft.jpg'),
    ).writeAsBytes(files['draft.jpg']!);
    final rig = _FakeRig(token: token, peerId: peerId, files: files);

    final report = await serviceFor(rig).pullJob(7);

    expect(report.alreadyPresent, 1);
    expect(report.pulled, 1);
    expect(rig.acks.length, 2);
    expect(
      rig.gets.where((u) => u.path.contains('/artifact/')).length,
      1,
      reason: 'the file that was already here was not downloaded again',
    );
  });

  test('a file here under the same name with different bytes is a conflict, '
      'never an overwrite', () async {
    final incoming = await Directory(
      p.join(tempDir.path, 'incoming'),
    ).create(recursive: true);
    final squatter = File(p.join(incoming.path, 'draft.jpg'));
    await squatter.writeAsString('SOMETHING-ELSE');
    final rig = _FakeRig(token: token, peerId: peerId, files: files);

    final report = await serviceFor(rig).pullJob(7);

    expect(report.failed, 1);
    expect(report.pulled, 1);
    expect(
      report.files.firstWhere((f) => f.entry.fileName == 'draft.jpg').problem,
      contains('destinationConflict'),
    );
    expect(await squatter.readAsString(), 'SOMETHING-ELSE');
    expect(
      rig.acks.length,
      1,
      reason: 'a file that did not land is never acknowledged',
    );
  });

  test('a file the rig could not serve is carried into the report', () async {
    final rig = _FakeRig(token: token, peerId: peerId, files: files);
    final withGap = DeliveryManifest(
      jobId: 7,
      peerId: peerId,
      generatedAt: DateTime.utc(2026, 8, 16, 6),
      entries: rig.manifest.entries,
      unavailable: const [
        UnavailableArtifact(
          artifactId: 'deadbeef',
          reason: 'sourceMissing: the master was deleted on the rig',
        ),
      ],
    );
    final gapRig = _ManifestOverrideRig(rig, withGap, token);

    final report = await serviceFor(gapRig).pullJob(7);

    expect(report.pulled, 2);
    expect(report.unavailable.length, 1);
    expect(
      report.complete,
      isFalse,
      reason: 'a night with a file the rig lost is not a complete pull',
    );
    expect(report.summary, contains('not served by the rig'));
  });
}

/// Serves a manifest the test supplies while delegating everything else to a
/// real fake rig.
class _ManifestOverrideRig implements ArtifactHttpClient {
  _ManifestOverrideRig(this.inner, this.manifest, this.token);

  final _FakeRig inner;
  final DeliveryManifest manifest;
  final String token;

  @override
  Future<ArtifactHttpResponse> get(Uri url, Map<String, String> headers) async {
    if (!url.path.contains('/manifest/')) return inner.get(url, headers);
    final signed = SignedDeliveryManifest.sign(
      manifest: manifest,
      authIdentity: computeServerFingerprint(token),
    );
    final bytes = utf8.encode(jsonEncode(signed.toJson()));
    return ArtifactHttpResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: Stream<List<int>>.fromIterable([bytes]),
      contentLength: bytes.length,
    );
  }

  @override
  Future<ArtifactHttpResponse> postJson(
    Uri url,
    Map<String, String> headers,
    Object? body,
  ) => inner.postJson(url, headers, body);

  @override
  void close() => inner.close();
}
