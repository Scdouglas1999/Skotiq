// SY-08: the host's own screens showed the focuser's connect-time temperature
// (19.2 °C) all night while the focuser and the host API reported 18.1 °C.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_backend.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

FocuserStatus _status(double temperature) => FocuserStatus(
  connected: true,
  position: 45362,
  moving: false,
  temperature: temperature,
  maxPosition: 600000,
  stepSize: 1,
  isAbsolute: true,
  hasTemperature: true,
);

ProviderContainer _container(SkotiqBackend backend) {
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  container.read(focuserTemperaturePollerProvider);
  final focuser = container.read(focuserStateProvider.notifier);
  focuser.setConnecting('native:zwo_eaf:0', 'EAF');
  focuser.setConnected(hasTemperature: true);
  focuser.updateTemperature(19.2);
  return container;
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  test('the host keeps reading the focuser temperature while idle', () {
    fakeAsync((async) {
      final backend = MockBackend();
      final readings = [18.4, 18.13];
      when(
        () => backend.getFocuserStatus('native:zwo_eaf:0'),
      ).thenAnswer((_) async => _status(readings.removeAt(0)));
      final container = _container(backend);

      async.elapse(const Duration(seconds: 30));
      expect(container.read(focuserStateProvider).temperature, 18.4);
      async.elapse(const Duration(seconds: 30));
      expect(container.read(focuserStateProvider).temperature, 18.13);

      container.read(focuserStateProvider.notifier).setDisconnected();
      async.elapse(const Duration(minutes: 2));
      verify(() => backend.getFocuserStatus('native:zwo_eaf:0')).called(2);
      container.dispose();
    });
  });

  test('a move in progress is left to the move to read', () {
    fakeAsync((async) {
      final backend = MockBackend();
      when(
        () => backend.getFocuserStatus(any()),
      ).thenAnswer((_) async => _status(18.0));
      final container = _container(backend);
      container.read(focuserStateProvider.notifier).setMoving(true);

      async.elapse(const Duration(seconds: 31));
      verifyNever(() => backend.getFocuserStatus(any()));
      expect(container.read(focuserStateProvider).temperature, 19.2);
      container.dispose();
    });
  });

  test('a linked client leaves it to the remote re-hydrate', () {
    fakeAsync((async) {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      final container = _container(backend);

      async.elapse(const Duration(minutes: 2));
      verifyNever(() => backend.getFocuserStatus(any()));
      container.dispose();
    });
  });
}
