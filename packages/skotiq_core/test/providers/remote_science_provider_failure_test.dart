import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

ProviderContainer _container(NetworkBackend backend) {
  return ProviderContainer(
    overrides: [
      backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
    ],
  );
}

Matcher _hasMessage(String message) =>
    isA<StateError>().having((error) => error.message, 'message', message);

void main() {
  test('remote session science providers preserve host failures', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.getScienceSessionBundle(9),
    ).thenThrow(StateError('session science unavailable'));
    final container = _container(backend);
    addTearDown(container.dispose);

    final futures = <Future<Object?>>[
      container.read(sessionPhotometryProvider(9).future),
      container.read(sessionFrameCalibrationsProvider(9).future),
      container.read(sessionTransparencySamplesProvider(9).future),
      container.read(sessionPsfTilesProvider(9).future),
      container.read(sessionFrameQualityMetricsProvider(9).future),
      container.read(sessionTileMetricsProvider(9).future),
      container.read(sessionResidualVectorsProvider(9).future),
      container.read(sessionMovingObjectCandidatesProvider(9).future),
      container.read(sessionLineRatioProductsProvider(9).future),
    ];

    for (final future in futures) {
      await expectLater(
        future,
        throwsA(_hasMessage('session science unavailable')),
      );
    }
    verify(() => backend.getScienceSessionBundle(9)).called(1);
  });

  test('remote standalone science providers preserve host failures', () async {
    final backend = _MockNetworkBackend();
    when(
      backend.getSessionlessScienceBundle,
    ).thenThrow(StateError('standalone science unavailable'));
    final container = _container(backend);
    addTearDown(container.dispose);

    final futures = <Future<Object?>>[
      container.read(sessionlessPhotometryProvider.future),
      container.read(sessionlessCalibrationsProvider.future),
      container.read(sessionlessTransparencySamplesProvider.future),
      container.read(sessionlessPsfTilesProvider.future),
      container.read(sessionlessFrameQualityMetricsProvider.future),
      container.read(sessionlessTileMetricsProvider.future),
      container.read(sessionlessResidualVectorsProvider.future),
      container.read(sessionlessMovingObjectCandidatesProvider.future),
      container.read(sessionlessLineRatioProductsProvider.future),
    ];

    for (final future in futures) {
      await expectLater(
        future,
        throwsA(_hasMessage('standalone science unavailable')),
      );
    }
    verify(backend.getSessionlessScienceBundle).called(1);
  });
}
