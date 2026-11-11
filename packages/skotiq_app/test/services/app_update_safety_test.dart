import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/services/app_update.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

class MockSkotiqBackend extends Mock implements SkotiqBackend {}

class TestBackendNotifier extends BackendNotifier {
  TestBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }
}

final updateSafetyProbeProvider = FutureProvider<void>((ref) {
  return defaultUpdateApplySafetyCheckWithReader(ref.read);
});

void main() {
  test(
    'default safety check checkpoints then blocks active sequence',
    () async {
      final backend = MockSkotiqBackend();
      when(() => backend.saveCheckpoint()).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;

      await expectLater(
        container.read(updateSafetyProbeProvider.future),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('running'),
          ),
        ),
      );
      verify(() => backend.saveCheckpoint()).called(1);
    },
  );

  test('default safety check blocks active camera cooler', () async {
    final backend = MockSkotiqBackend();

    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final camera = container.read(cameraStateProvider.notifier);
    camera.setConnecting('cam1', 'Camera');
    camera.setConnected();
    camera.setCooling(true);

    await expectLater(
      container.read(updateSafetyProbeProvider.future),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('cooler'),
        ),
      ),
    );
    verifyNever(() => backend.saveCheckpoint());
  });

  test('default safety check blocks unparked mount', () async {
    final backend = MockSkotiqBackend();

    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final mount = container.read(mountStateProvider.notifier);
    mount.setConnecting('mount1');
    mount.setConnected();
    mount.setParked(false);

    await expectLater(
      container.read(updateSafetyProbeProvider.future),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('parked'),
        ),
      ),
    );
    verifyNever(() => backend.saveCheckpoint());
  });
}
