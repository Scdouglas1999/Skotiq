// The rig's peer-delivery endpoints against a real v58 database.
//
// What is pinned here: a manifest signed for the calling principal and
// round-tripped by the client parser, refusals for an id or a peer this job
// never published for, RFC 7233 serving that the resumable downloader can
// resume against, and an acknowledgement that only closes a row when the
// checksum agrees with the rig's own copy.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/handlers/darkroom_delivery_handlers.dart';
import 'package:skotiq_desktop/headless_api/request_context.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DarkroomDeliveryHandlers', () {
    late ProviderContainer container;
    late SkotiqDatabase db;
    late DarkroomDeliveryHandlers handlers;
    late Directory tempDir;
    late int jobId;
    late int targetId;
    late DeliveryArtifactSet published;

    const identity = 'fingerprint-of-the-paired-desktop';

    setUp(() async {
      container = createHeadlessTestContainer();
      db = container.read(databaseProvider);
      handlers = DarkroomDeliveryHandlers(container);
      tempDir = await Directory.systemTemp.createTemp('sk_delivery_api_');

      jobId = await DarkroomJobsDao(db).enqueue();
      targetId = await DeliveryTargetsDao(db).create(
        name: 'office-pc',
        kind: ArtifactDestinationKind.peer,
        // `rigId` is pinned so the name the desktop writes does not depend on
        // this machine's host name; the component itself is covered in
        // skotiq_core's delivery_naming_test.dart.
        configJson: jsonEncode({'peerId': 'office-pc', 'rigId': 'shed-rig'}),
        content: const {ArtifactContent.linearMasters},
      );

      final master = File(p.join(tempDir.path, 'M31_Ha_master.fits'));
      await master.writeAsString('MASTER-LIGHT-BYTES-FOR-THE-DESKTOP');
      published = await DeliveryArtifactSet.build(
        jobId: jobId,
        sources: {
          ArtifactContent.linearMasters: [master.path],
        },
      );
      await DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (destination, id) =>
            PeerPublicationTransport(destination: destination, jobId: id),
      ).deliverJobArtifacts(published);
    });

    tearDown(() async {
      container.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    String artifactIdOfMaster() =>
        artifactIdForPath(published.artifacts.single.sourcePath);

    Request authed(String url) => Request(
      'GET',
      Uri.parse(url),
      context: const {authIdentityContextKey: identity},
    );

    Future<Response> manifest({
      String query = '?peer=office-pc',
      bool withIdentity = true,
      String job = '',
    }) {
      final id = job.isEmpty ? '$jobId' : job;
      final url = 'http://localhost/api/darkroom/delivery/manifest/$id$query';
      return translateHandlerErrors(
        handlers.handleGetDeliveryManifest(
          withIdentity ? authed(url) : Request('GET', Uri.parse(url)),
          id,
        ),
      );
    }

    Future<Response> artifact({
      String? id,
      String query = '?peer=office-pc',
      Map<String, String> headers = const {},
    }) {
      final String wanted = id ?? artifactIdOfMaster();
      final url =
          'http://localhost/api/darkroom/delivery/artifact/$jobId/$wanted$query';
      return translateHandlerErrors(
        handlers.handleDownloadDeliveryArtifact(
          Request(
            'GET',
            Uri.parse(url),
            headers: headers,
            context: const {authIdentityContextKey: identity},
          ),
          '$jobId',
          wanted,
        ),
      );
    }

    Future<Response> ack(Map<String, Object?> body) {
      return translateHandlerErrors(
        handlers.handleAcknowledgeDelivery(
          Request(
            'POST',
            Uri.parse('http://localhost/api/darkroom/delivery/ack/$jobId'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body),
            context: const {authIdentityContextKey: identity},
          ),
          '$jobId',
        ),
      );
    }

    group('the manifest', () {
      test('round-trips into the client parser and verifies for the calling '
          'principal', () async {
        final response = await manifest();

        expect(response.statusCode, HttpStatus.ok);
        final signed = SignedDeliveryManifest.fromJson(
          jsonDecode(await response.readAsString()),
        );
        expect(signed.verify(identity), isTrue);
        expect(signed.manifest.jobId, jobId);
        expect(signed.manifest.peerId, 'office-pc');
        final entry = signed.manifest.entries.single;
        expect(entry.artifactId, artifactIdOfMaster());
        expect(entry.targetId, targetId);
        expect(
          entry.fileName,
          'shed-rig-M31_Ha_master.fits',
          reason:
              'the desktop writes a name that says which rig it came '
              'from, so two rigs pulling into one folder do not collide',
        );
        expect(entry.checksum, published.artifacts.single.checksum);
        expect(entry.bytes, published.artifacts.single.bytes);
      });

      test('is published unsigned, with the reason, when the server '
          'authenticated no principal', () async {
        final response = await manifest(withIdentity: false);

        final signed = SignedDeliveryManifest.fromJson(
          jsonDecode(await response.readAsString()),
        );
        expect(signed.signature, isNull);
        expect(
          signed.signatureAbsentReason,
          contains('authenticated no principal'),
        );
        expect(signed.verify(identity), isFalse);
      });

      test('does not verify for a different principal', () async {
        final response = await manifest();

        final signed = SignedDeliveryManifest.fromJson(
          jsonDecode(await response.readAsString()),
        );
        expect(signed.verify('some-other-desktop'), isFalse);
      });

      test('refuses a caller that is not a configured peer', () async {
        final response = await manifest(query: '?peer=not-a-peer');

        expect(response.statusCode, HttpStatus.notFound);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['error'], 'unknown_delivery_peer');
      });

      test('refuses a request that names no peer at all', () async {
        final response = await manifest(query: '');

        expect(response.statusCode, HttpStatus.badRequest);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['field'], 'peer');
      });

      test('refuses a job id that is not a job id', () async {
        final response = await manifest(job: 'latest');

        expect(response.statusCode, HttpStatus.badRequest);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['field'], 'jobId');
      });
    });

    group('serving the bytes', () {
      test('answers a whole-file request with the bytes, an ETag and '
          'accept-ranges', () async {
        final response = await artifact();

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['accept-ranges'], 'bytes');
        expect(
          response.headers['etag'],
          startsWith('"${artifactIdOfMaster()}-'),
        );
        expect(response.headers['content-type'], 'application/fits');
        expect(
          await response.readAsString(),
          'MASTER-LIGHT-BYTES-FOR-THE-DESKTOP',
        );
      });

      test('names the file the way the manifest promised it', () async {
        // The header used to carry the rig's own file name while the manifest
        // listed `shed-rig-<name>`. Skotiq's puller writes the manifest
        // entry's name and never noticed; `curl -OJ`, a browser or any
        // third-party puller writes what this header says — which is exactly
        // the two-rigs-one-share collision the namespacing exists to prevent.
        final listed =
            jsonDecode(await (await manifest()).readAsString())
                as Map<String, Object?>;
        final entries =
            (listed['manifest']! as Map<String, Object?>)['entries']! as List;
        final promised =
            (entries.single as Map<String, Object?>)['fileName'] as String;
        expect(promised, startsWith('shed-rig-'));

        for (final response in [
          await artifact(),
          await artifact(headers: {'range': 'bytes=0-4'}),
        ]) {
          expect(
            response.headers['content-disposition'],
            'attachment; filename="$promised"',
          );
        }
      });

      test('answers a Range request with 206 and a Content-Range', () async {
        final response = await artifact(headers: {'range': 'bytes=7-12'});

        expect(response.statusCode, HttpStatus.partialContent);
        expect(
          response.headers['content-range'],
          'bytes 7-12/${published.artifacts.single.bytes}',
        );
        expect(await response.readAsString(), 'LIGHT-');
      });

      test('ignores a Range whose If-Range no longer matches', () async {
        final response = await artifact(
          headers: {'range': 'bytes=7-12', 'if-range': '"stale-etag"'},
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(
          await response.readAsString(),
          'MASTER-LIGHT-BYTES-FOR-THE-DESKTOP',
        );
      });

      test(
        'answers an unsatisfiable range with 416 and the resource size',
        () async {
          final response = await artifact(
            headers: {'range': 'bytes=9000-9999'},
          );

          expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
          expect(
            response.headers['content-range'],
            'bytes */${published.artifacts.single.bytes}',
          );
        },
      );

      test('refuses an id this job never published', () async {
        final response = await artifact(id: artifactIdForPath('/etc/passwd'));

        expect(response.statusCode, HttpStatus.notFound);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['error'], 'artifact_not_published');
      });

      test('refuses a path used as an id', () async {
        final response = await artifact(id: '..%2F..%2Fetc%2Fpasswd');

        expect(response.statusCode, HttpStatus.notFound);
      });

      test('refuses a peer the publication does not belong to', () async {
        await DeliveryTargetsDao(db).create(
          name: 'laptop',
          kind: ArtifactDestinationKind.peer,
          configJson: jsonEncode({'peerId': 'laptop'}),
          content: const {ArtifactContent.linearMasters},
        );

        final response = await artifact(query: '?peer=laptop');

        expect(response.statusCode, HttpStatus.notFound);
      });

      test(
        'says the file is gone rather than serving nothing as success',
        () async {
          await File(published.artifacts.single.sourcePath).delete();

          final response = await artifact();

          expect(response.statusCode, HttpStatus.notFound);
          final body =
              jsonDecode(await response.readAsString()) as Map<String, dynamic>;
          expect(body['error'], 'artifact_missing');
        },
      );
    });

    group('acknowledging', () {
      test('closes the journal row the manifest published', () async {
        final response = await ack({
          'peerId': 'office-pc',
          'artifactId': artifactIdOfMaster(),
          'checksum': published.artifacts.single.checksum,
        });

        expect(response.statusCode, HttpStatus.ok);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['state'], 'delivered');
        expect(body['targetId'], targetId);
        expect(body['deliveredAt'], isNotNull);

        final row = (await DeliveryJournalDao(db).listForJob(jobId)).single;
        expect(row.state, DeliveryAttemptState.delivered);
      });

      test('refuses a checksum that is not the one on the rig', () async {
        final response = await ack({
          'peerId': 'office-pc',
          'artifactId': artifactIdOfMaster(),
          'checksum': 'de' * 32,
        });

        expect(response.statusCode, HttpStatus.conflict);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['error'], 'checksum_mismatch');
        final row = (await DeliveryJournalDao(db).listForJob(jobId)).single;
        expect(row.state, DeliveryAttemptState.retrying);
      });

      test('refuses an id nothing published', () async {
        final response = await ack({
          'peerId': 'office-pc',
          'artifactId': artifactIdForPath('/etc/shadow'),
          'checksum': 'de' * 32,
        });

        expect(response.statusCode, HttpStatus.notFound);
      });

      test('refuses a caller that is not a configured peer', () async {
        final response = await ack({
          'peerId': 'not-a-peer',
          'artifactId': artifactIdOfMaster(),
          'checksum': published.artifacts.single.checksum,
        });

        expect(response.statusCode, HttpStatus.notFound);
      });

      test('refuses a body with no peer id', () async {
        final response = await ack({
          'artifactId': artifactIdOfMaster(),
          'checksum': published.artifacts.single.checksum,
        });

        expect(response.statusCode, HttpStatus.badRequest);
      });
    });
  });

  group('the delivery endpoints are authenticated', () {
    const paths = [
      '/api/darkroom/delivery/manifest/<jobId>',
      '/api/darkroom/delivery/artifact/<jobId>/<artifactId>',
      '/api/darkroom/delivery/ack/<jobId>',
    ];

    test('none of them is public', () {
      for (final path in paths) {
        expect(
          HeadlessAuthPolicy.requiredCapabilityFor(
            method: path.endsWith('<jobId>') && path.contains('/ack/')
                ? 'POST'
                : 'GET',
            path: path,
          ).public,
          isFalse,
          reason: '$path must never be reachable without a token',
        );
      }
    });

    test('reading a manifest or an artifact needs control, not view', () {
      // This assertion used to require only a view token, which is what the
      // routes actually did: with no entry in `resourcePrefixKeys` and no
      // scope rule, both GETs fell through to the method default. The manifest
      // lists every master this job published with its size and SHA-256 and
      // the artifact route streams those masters byte-for-byte, so a read-only
      // credential — the phone by the bed, a shared run-watch link — must not
      // reach either.
      for (final path in paths.take(2)) {
        expect(
          HeadlessAuthPolicy.requiredScopeFor(method: 'GET', path: path),
          HeadlessTokenScope.control,
        );
        expect(
          HeadlessAuthPolicy.allows(
            actual: HeadlessTokenScope.view,
            method: 'GET',
            path: path,
          ),
          isFalse,
          reason: 'a read-only credential cannot pull the published masters',
        );
        expect(
          HeadlessAuthPolicy.allows(
            actual: HeadlessTokenScope.control,
            method: 'GET',
            path: path,
          ),
          isTrue,
          reason: 'the paired desktop collecting its night still can',
        );
      }
    });

    test('acknowledging is a write and needs control', () {
      const path = '/api/darkroom/delivery/ack/<jobId>';

      expect(
        HeadlessAuthPolicy.requiredScopeFor(method: 'POST', path: path),
        HeadlessTokenScope.control,
      );
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.view,
          method: 'POST',
          path: path,
        ),
        isFalse,
        reason: 'a view-only phone cannot close a delivery it did not make',
      );
    });
  });
}
