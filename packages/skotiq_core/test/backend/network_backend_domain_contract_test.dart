import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/models/errors/server_error.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

void main() {
  group('NetworkBackend target and sequence contracts', () {
    test('valid empty host collections remain empty', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/targets', body: '{"targets":[]}')
        ..setResponse(
          '/api/sequence-management/list-full',
          body: '{"sequences":[]}',
        )
        ..setResponse(
          '/api/sequence-management/7/full',
          body: '{"sequence":{"databaseId":7,"name":"M42"}}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(await backend.getAllTargets(), isEmpty);
      expect(await backend.listFullSequences(), isEmpty);
      expect((await backend.getFullSequence(7))?['databaseId'], 7);
    });

    test('missing and malformed collection fields fail loudly', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/targets', body: '{}')
        ..setResponse(
          '/api/targets/favorites',
          body: '{"targets":["not an object"]}',
        )
        ..setResponse('/api/sequence-management/list', body: '{}')
        ..setResponse(
          '/api/sequence-management/templates-full',
          body: '{"templates":false}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.getAllTargets(), throwsFormatException);
      await expectLater(backend.getFavoriteTargets(), throwsFormatException);
      await expectLater(backend.getSequenceList(), throwsFormatException);
      await expectLater(backend.listFullTemplates(), throwsFormatException);
    });

    test('only a 404 means target or sequence not found', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/targets/4',
          status: 404,
          body: '{"code":"not_found","message":"Target not found"}',
        )
        ..setResponse(
          '/api/sequence-management/8',
          status: 404,
          body: '{"code":"not_found","message":"Sequence not found"}',
        )
        ..setResponse(
          '/api/sequence-management/8/full',
          status: 404,
          body: '{"code":"not_found","message":"Sequence not found"}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(await backend.getTargetById(4), isNull);
      expect(await backend.getSequenceDetails(8), isNull);
      expect(await backend.getFullSequence(8), isNull);
    });

    test('detail auth failures are not reported as not found', () {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/targets/4',
          status: 401,
          body: '{"code":"unauthorized","message":"Pairing token expired"}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(backend.getTargetById(4), throwsA(isA<ServerError>()));
    });

    test('create responses require the persisted host ID', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/targets', method: 'POST', body: '{}')
        ..setResponse(
          '/api/sequence-management/save-full',
          method: 'POST',
          body: '{}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.createTarget({}), throwsFormatException);
      await expectLater(backend.saveFullSequence({}), throwsFormatException);
    });

    test(
      'sequence library metadata and version routes decode strictly',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/sequence-management/summaries',
            body: jsonEncode({
              'summaries': [
                {
                  'id': 7,
                  'name': 'M42 remote',
                  'nodeCount': 4,
                  'targetCount': 1,
                  'exposureCount': 2,
                  'totalIntegrationSecs': 3600,
                  'primaryTargetName': 'M42',
                  'lastRunAt': '2026-01-03T02:00:00Z',
                  'runCount': 3,
                  'tags': ['winter', 'narrowband'],
                  'isFavorite': true,
                  'createdAt': '2026-01-01T00:00:00Z',
                  'modifiedAt': '2026-01-02T00:00:00Z',
                },
              ],
            }),
          )
          ..setResponse(
            '/api/sequence-management/7/tags',
            method: 'PUT',
            body: '{"status":"updated"}',
          )
          ..setResponse(
            '/api/sequence-management/7/favorite',
            method: 'POST',
            body: '{"isFavorite":false}',
          )
          ..setResponse(
            '/api/sequence-management/7/versions',
            method: 'POST',
            body: '{"id":11}',
          )
          ..setResponse(
            '/api/sequence-management/7/versions',
            body: jsonEncode({
              'versions': [
                {
                  'id': 11,
                  'sequenceId': 7,
                  'label': 'before filter edit',
                  'createdAt': '2026-01-04T00:00:00Z',
                },
              ],
            }),
          )
          ..setResponse(
            '/api/sequence-management/versions/11',
            body: jsonEncode({
              'version': {
                'id': 11,
                'sequenceId': 7,
                'snapshotJson': '{"name":"M42 remote"}',
                'label': 'before filter edit',
                'createdAt': '2026-01-04T00:00:00Z',
              },
            }),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        final summary = (await backend.listSequenceSummaries()).single;
        expect(summary.tags, ['winter', 'narrowband']);
        expect(summary.isFavorite, isTrue);
        expect(summary.runCount, 3);

        await backend.setSequenceTags(7, ['winter']);
        expect(await backend.toggleSequenceFavorite(7), isFalse);
        expect(
          await backend.snapshotSequenceVersion(7, {
            'name': 'M42 remote',
          }, label: 'before filter edit'),
          11,
        );
        final listed = (await backend.listSequenceVersions(7)).single;
        expect(listed.id, 11);
        expect((await backend.getSequenceVersion(11))?.sequenceId, 7);

        final tagsBody =
            jsonDecode(
                  fake
                      .requestsFor('/api/sequence-management/7/tags')
                      .single
                      .body!,
                )
                as Map<String, dynamic>;
        expect(tagsBody['tags'], ['winter']);
        final snapshotBody =
            jsonDecode(
                  fake
                      .requestsFor('/api/sequence-management/7/versions')
                      .firstWhere((request) => request.method == 'POST')
                      .body!,
                )
                as Map<String, dynamic>;
        expect(snapshotBody['label'], 'before filter edit');
      },
    );

    test('malformed sequence summary metadata fails instead of defaulting', () {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequence-management/summaries',
          body: jsonEncode({
            'summaries': [
              {
                'id': 7,
                'name': 'M42 remote',
                'nodeCount': 4,
                'targetCount': 1,
                'exposureCount': 2,
                'totalIntegrationSecs': 3600,
                'primaryTargetName': 'M42',
                'lastRunAt': null,
                'runCount': 0,
                // tags intentionally missing
                'isFavorite': true,
                'createdAt': '2026-01-01T00:00:00Z',
                'modifiedAt': '2026-01-02T00:00:00Z',
              },
            ],
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(backend.listSequenceSummaries(), throwsFormatException);
    });

    test('fractional persisted IDs are rejected instead of truncated', () {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequence-management/save-full',
          method: 'POST',
          body: '{"id":7.5}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(backend.saveFullSequence({}), throwsFormatException);
    });

    test(
      'named atlas regions are created on the host with a strict id',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/atlas/regions',
            method: 'POST',
            body: '{"id":42}',
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        final id = await backend.createAtlasRegion(
          name: 'M31 core',
          centerRaDeg: 10.68,
          centerDecDeg: 41.27,
          radiusDeg: 1.5,
          kind: 'target',
          targetId: 31,
        );

        expect(id, 42);
        final body =
            jsonDecode(fake.requestsFor('/api/atlas/regions').single.body!)
                as Map<String, dynamic>;
        expect(body, {
          'name': 'M31 core',
          'centerRaDeg': 10.68,
          'centerDecDeg': 41.27,
          'radiusDeg': 1.5,
          'kind': 'target',
          'targetId': 31,
        });
      },
    );

    test('atlas region creation rejects a fractional host id', () {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/atlas/regions',
          method: 'POST',
          body: '{"id":42.5}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(
        backend.createAtlasRegion(
          name: 'M31',
          centerRaDeg: 10.68,
          centerDecDeg: 41.27,
          radiusDeg: 1.5,
          kind: 'custom',
        ),
        throwsFormatException,
      );
    });
  });
}
