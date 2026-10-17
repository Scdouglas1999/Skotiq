import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

void main() {
  group('NetworkBackend planning and observing-list contracts', () {
    test('valid empty host collections remain empty', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/integration-goals', body: '{"goals":[]}')
        ..setResponse('/api/target-constraints', body: '{"constraints":[]}')
        ..setResponse('/api/horizon-profiles', body: '{"profiles":[]}')
        ..setResponse('/api/projects', body: '{"projects":[]}')
        ..setResponse('/api/observing-lists', body: '{"lists":[]}')
        ..setResponse(
          '/api/observing-lists/listed-catalog-ids',
          body: '{"catalogIds":[]}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(await backend.getIntegrationGoals(), isEmpty);
      expect(await backend.getTargetConstraints(), isEmpty);
      expect(await backend.getHorizonProfiles(), isEmpty);
      expect(await backend.getProjects(), isEmpty);
      expect(await backend.getObservingLists(), isEmpty);
      expect(await backend.getListedCatalogIds(), isEmpty);
    });

    test('missing collection fields do not impersonate empty data', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/integration-goals', body: '{}')
        ..setResponse('/api/target-constraints', body: '{}')
        ..setResponse('/api/horizon-profiles', body: '{}')
        ..setResponse('/api/projects', body: '{}')
        ..setResponse('/api/observing-lists', body: '{}')
        ..setResponse('/api/observing-lists/listed-catalog-ids', body: '{}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.getIntegrationGoals(), throwsFormatException);
      await expectLater(backend.getTargetConstraints(), throwsFormatException);
      await expectLater(backend.getHorizonProfiles(), throwsFormatException);
      await expectLater(backend.getProjects(), throwsFormatException);
      await expectLater(backend.getObservingLists(), throwsFormatException);
      await expectLater(backend.getListedCatalogIds(), throwsFormatException);
    });

    test('malformed rows and catalog IDs fail loudly', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/integration-goals', body: '{"goals":[false]}')
        ..setResponse('/api/observing-lists', body: '{"lists":["broken"]}')
        ..setResponse(
          '/api/observing-lists/listed-catalog-ids',
          body: '{"catalogIds":["M31",3]}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.getIntegrationGoals(), throwsFormatException);
      await expectLater(backend.getObservingLists(), throwsFormatException);
      await expectLater(backend.getListedCatalogIds(), throwsFormatException);
    });

    test(
      'required counts and mutation IDs cannot silently become zero',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse('/api/integration-goals/captured-count', body: '{}')
          ..setResponse('/api/observing-lists', method: 'POST', body: '{}')
          ..setResponse(
            '/api/observing-lists/duplicate',
            method: 'POST',
            body: '{}',
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        await expectLater(
          backend.getCapturedFrameCount(targetId: 7, filter: 'Ha'),
          throwsFormatException,
        );
        await expectLater(
          backend.createObservingList(name: 'Launch targets'),
          throwsFormatException,
        );
        await expectLater(
          backend.duplicateObservingList(4),
          throwsFormatException,
        );
      },
    );
  });
}
