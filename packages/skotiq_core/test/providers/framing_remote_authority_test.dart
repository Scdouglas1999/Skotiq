import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

class _NoIoFramingNotifier extends FramingNotifier {
  _NoIoFramingNotifier(super.ref);

  @override
  Future<void> loadSurveyImage({double? canvasWidthLogicalPx}) async {}

  @override
  Future<void> persistLastFramedTarget(FramingTarget target) async {}
}

void main() {
  test(
    'rapid target changes only push the latest target to the host',
    () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.framingSetTarget(
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          name: any(named: 'name'),
        ),
      ).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          framingProvider.overrideWith(_NoIoFramingNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(framingProvider.notifier);
      notifier.setTargetCoordinates(1, 10, name: 'First');
      notifier.setTargetCoordinates(2, 20, name: 'Latest');
      await Future<void>.delayed(Duration.zero);

      verify(
        () => backend.framingSetTarget(ra: 2, dec: 20, name: 'Latest'),
      ).called(1);
      verifyNever(
        () => backend.framingSetTarget(ra: 1, dec: 10, name: 'First'),
      );
    },
  );

  test(
    'host switch clears the target and releases the old push queue',
    () async {
      final hostA = _MockNetworkBackend();
      final hostB = _MockNetworkBackend();
      final hostAGate = Completer<void>();
      when(
        () => hostA.framingSetTarget(ra: 1, dec: 10, name: 'Rig A target'),
      ).thenAnswer((_) => hostAGate.future);
      when(
        () => hostB.framingSetTarget(ra: 2, dec: 20, name: 'Rig B target'),
      ).thenAnswer((_) async {});
      late _SwappableBackendNotifier backendNotifier;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            backendNotifier = _SwappableBackendNotifier(ref, hostA);
            return backendNotifier;
          }),
          framingProvider.overrideWith(_NoIoFramingNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(framingProvider.notifier);

      notifier.setTargetCoordinates(1, 10, name: 'Rig A target');
      await Future<void>.delayed(Duration.zero);
      backendNotifier.replaceWith(hostB);
      expect(container.read(framingProvider).target, isNull);

      notifier.setTargetCoordinates(2, 20, name: 'Rig B target');
      await Future<void>.delayed(Duration.zero);
      verify(
        () => hostB.framingSetTarget(ra: 2, dec: 20, name: 'Rig B target'),
      ).called(1);

      hostAGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(container.read(framingProvider).target?.name, 'Rig B target');
    },
  );

  test('failed fire-and-forget target push is contained', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.framingSetTarget(ra: 1, dec: 10, name: 'M42'),
    ).thenThrow(StateError('host offline'));
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, backend),
        ),
        framingProvider.overrideWith(_NoIoFramingNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(framingProvider.notifier)
        .setTargetCoordinates(1, 10, name: 'M42');
    await Future<void>.delayed(Duration.zero);

    expect(container.read(framingProvider).target?.name, 'M42');
    verify(
      () => backend.framingSetTarget(ra: 1, dec: 10, name: 'M42'),
    ).called(1);
  });
}
