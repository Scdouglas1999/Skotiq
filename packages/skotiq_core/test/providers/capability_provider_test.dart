import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/capability_provider.dart';

import '../mocks/mock_backend.dart';

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
}
