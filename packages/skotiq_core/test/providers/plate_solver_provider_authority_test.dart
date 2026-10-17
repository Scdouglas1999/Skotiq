import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockPlateSolveService extends Mock implements PlateSolveService {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void swap(SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

ProviderContainer _container(_MockPlateSolveService service) {
  return ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
      ),
      plateSolveServiceProvider.overrideWithValue(service),
    ],
  );
}

void main() {
  test(
    'detection and preferences reload when the active backend changes',
    () async {
      final service = _MockPlateSolveService();
      var detectionCalls = 0;
      var preferenceCalls = 0;
      when(service.detect).thenAnswer((_) async {
        detectionCalls++;
        return PlateSolverDetection(astapPath: '/host-$detectionCalls/astap');
      });
      when(service.getConfig).thenAnswer((_) async {
        preferenceCalls++;
        return PlateSolverPreference(astapPath: '/host-$preferenceCalls/astap');
      });

      final container = _container(service);
      addTearDown(container.dispose);
      final detectionSubscription = container.listen(
        plateSolverDetectionProvider,
        (_, __) {},
        fireImmediately: true,
      );
      final preferenceSubscription = container.listen(
        plateSolverPreferenceProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(detectionSubscription.close);
      addTearDown(preferenceSubscription.close);

      expect(
        (await container.read(plateSolverDetectionProvider.future)).astapPath,
        '/host-1/astap',
      );
      expect(
        (await container.read(plateSolverPreferenceProvider.future)).astapPath,
        '/host-1/astap',
      );

      final backend =
          container.read(backendProvider.notifier) as _SwappableBackendNotifier;
      backend.swap(DisconnectedBackend());

      expect(
        (await container.read(plateSolverDetectionProvider.future)).astapPath,
        '/host-2/astap',
      );
      expect(
        (await container.read(plateSolverPreferenceProvider.future)).astapPath,
        '/host-2/astap',
      );
      expect(detectionCalls, 2);
      expect(preferenceCalls, 2);
    },
  );

  test('rescan is single-flight and exposes its own busy state', () async {
    final service = _MockPlateSolveService();
    final detection = Completer<PlateSolverDetection>();
    var detectionCalls = 0;
    when(service.detect).thenAnswer((_) {
      detectionCalls++;
      return detection.future;
    });

    final container = _container(service);
    addTearDown(container.dispose);
    final notifier = container.read(
      plateSolverSettingsNotifierProvider.notifier,
    );

    final first = notifier.rescan();
    expect(
      container.read(plateSolverSettingsNotifierProvider).rescanning,
      isTrue,
    );
    final callsAfterFirstTap = detectionCalls;
    expect(await notifier.rescan(), isFalse);
    expect(detectionCalls, callsAfterFirstTap);

    detection.complete(const PlateSolverDetection());
    expect(await first, isTrue);
    expect(
      container.read(plateSolverSettingsNotifierProvider).rescanning,
      isFalse,
    );
  });

  test(
    'host switch clears verification and ignores the old-host result',
    () async {
      final service = _MockPlateSolveService();
      final verification = Completer<PlateSolverInfo>();
      when(() => service.verify(any())).thenAnswer((_) => verification.future);

      final container = _container(service);
      addTearDown(container.dispose);
      final notifier = container.read(
        plateSolverSettingsNotifierProvider.notifier,
      );

      final pending = notifier.verifyAstap('/old-host/astap');
      expect(
        container.read(plateSolverSettingsNotifierProvider).verifying,
        isTrue,
      );

      final backend =
          container.read(backendProvider.notifier) as _SwappableBackendNotifier;
      backend.swap(DisconnectedBackend());
      expect(
        container.read(plateSolverSettingsNotifierProvider),
        isA<PlateSolverSettingsState>()
            .having((state) => state.verifying, 'verifying', isFalse)
            .having((state) => state.astapVerifyInfo, 'ASTAP result', isNull),
      );

      verification.complete(
        const PlateSolverInfo(
          path: '/old-host/astap',
          flavour: 'ASTAP',
          versionLine: 'old host',
        ),
      );
      await pending;

      expect(
        container.read(plateSolverSettingsNotifierProvider).astapVerifyInfo,
        isNull,
      );
    },
  );
}
