import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/capability_provider.dart';
import 'package:skotiq_core/src/providers/equipment/camera_state_provider.dart';

import '../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  group('camera binning capability options', () {
    test('unknown and unsupported cameras expose only native 1x1', () {
      expect(getBinningOptionsFromCapabilities(null), ['1x1']);
      expect(
        getBinningOptionsFromCapabilities(
          const CameraCapabilities(
            maxWidth: 3000,
            maxHeight: 2000,
            bitDepth: 16,
          ),
        ),
        ['1x1'],
      );
    });

    test('uses the real symmetric driver range', () {
      expect(
        getBinningOptionsFromCapabilities(
          const CameraCapabilities(
            maxWidth: 3000,
            maxHeight: 2000,
            bitDepth: 16,
            canBin: true,
            maxBinX: 3,
            maxBinY: 2,
          ),
        ),
        ['1x1', '2x2'],
      );
    });

    test('loading and failed capability reads remain fail closed', () async {
      final backend = MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.getCameraCapabilities('camera'),
      ).thenThrow(Exception('host unavailable'));
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(cameraBinningOptionsProvider('camera')), ['1x1']);
      await expectLater(
        container.read(cameraCapabilitiesProvider('camera').future),
        throwsException,
      );
      expect(container.read(cameraBinningOptionsProvider('camera')), ['1x1']);
    });
  });

  /// 2026-11-08 on the rig: read while the ASI1600 was still connecting, the
  /// native driver answered with a 0 x 0, 0-bit sensor, the answer was kept
  /// for the life of the app, and the pre-flight check said "Connect a
  /// camera" with the camera connected.
  test(
    'capabilities are read again when the camera finishes connecting',
    () async {
      final backend = MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      var connected = false;
      when(() => backend.getCameraCapabilities('native:zwo:1')).thenAnswer(
        (_) async => connected
            ? const CameraCapabilities(
                maxWidth: 4656,
                maxHeight: 3520,
                bitDepth: 12,
              )
            : const CameraCapabilities(maxWidth: 0, maxHeight: 0, bitDepth: 0),
      );
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        cameraCapabilitiesProvider('native:zwo:1'),
        (_, _) {},
      );
      addTearDown(subscription.close);

      container
          .read(cameraStateProvider.notifier)
          .setConnecting('native:zwo:1', 'ZWO ASI1600MM-Cool');
      final early = await container.read(
        cameraCapabilitiesProvider('native:zwo:1').future,
      );
      expect(early?.maxWidth, 0);

      connected = true;
      container.read(cameraStateProvider.notifier).setConnected();
      final late = await container.read(
        cameraCapabilitiesProvider('native:zwo:1').future,
      );
      expect(late?.maxWidth, 4656);
      expect(late?.bitDepth, 12);
    },
  );
}
