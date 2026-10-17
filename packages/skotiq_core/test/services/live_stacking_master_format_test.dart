// The stacked master is a FITS data product, and the writer has to say what it
// wrote.
//
// Live finding ND-6: Live Stacking → Stop → "Save master" → typed
// `/tmp/ns-audit/waveD-imaging-spine/stack_master.fits` → the log recorded
// `Saving PNG file: …/stack_master.png` and the file on disk was
// `PNG image data, 1920 x 1080, 16-bit grayscale`. The 16-bit depth survives,
// but a "stacked master" saved as PNG carries no FITS header, no WCS and no
// integration metadata — and the extension swap was never disclosed.
//
// Owner decision 8 settled it: the master saves as FITS, with `EXPTIME` /
// `DATE-OBS` synthesized native-side from the stack's own provenance. These
// tests pin which writer a destination routes to, and that a request the
// stacker cannot serve is refused with the reason rather than rewritten.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/services/live_stacking_service.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, NetworkBackend backend) {
    state = backend;
  }
}

void main() {
  /// What the native FITS writer was asked for, so a test can tell a real write
  /// from a silently-rewritten one.
  final fitsRequests = <String>[];

  Future<bridge.ApiLiveStackingMaster> fakeSaveFits({
    required String filePath,
  }) async {
    fitsRequests.add(filePath);
    return bridge.ApiLiveStackingMaster(
      filePath: filePath,
      stackedFrameCount: 12,
      totalIntegrationSecs: 1440.0,
      dateObs: '2026-08-14T03:21:09.000',
    );
  }

  /// A container whose live-stacking service writes through [fakeSaveFits].
  /// With no backend override the backend is the local (non-network) default,
  /// so the service takes the in-process FFI path.
  ProviderContainer localContainer() {
    final container = ProviderContainer(
      overrides: [
        liveStackingServiceProvider.overrideWith(
          (ref) => LiveStackingService(ref, saveFitsMaster: fakeSaveFits),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(fitsRequests.clear);

  test(
    'a .fits destination is written as FITS, not rewritten to PNG',
    () async {
      final service = localContainer().read(liveStackingServiceProvider);

      final saved = await service.saveMaster(
        filePath: '/tmp/stack_master.fits',
      );

      expect(fitsRequests, ['/tmp/stack_master.fits']);
      expect(saved.filePath, '/tmp/stack_master.fits');
      expect(saved.format, LiveStackingMasterFormat.fitsMaster);
      expect(saved.totalIntegrationSecs, 1440.0);
      expect(saved.dateObs, '2026-08-14T03:21:09.000');
    },
  );

  test('a destination with no extension defaults to the FITS master', () async {
    final service = localContainer().read(liveStackingServiceProvider);

    final saved = await service.saveMaster(filePath: '/tmp/stack_master');

    expect(fitsRequests, ['/tmp/stack_master.fits']);
    expect(saved.format, LiveStackingMasterFormat.fitsMaster);
  });

  test('a .tif destination is refused rather than rewritten', () async {
    final service = localContainer().read(liveStackingServiceProvider);

    await expectLater(
      service.saveMaster(filePath: '/tmp/stack_master.tif'),
      throwsA(
        isA<LiveStackingMasterFormatUnsupported>()
            .having((e) => e.requestedExtension, 'extension', '.tif')
            .having((e) => e.toString(), 'message', contains('.fits')),
      ),
    );
    expect(fitsRequests, isEmpty);
  });

  group('remote client', () {
    late _MockNetworkBackend backend;
    late ProviderContainer container;

    setUp(() {
      backend = _MockNetworkBackend();
      when(() => backend.stackingGetResult()).thenAnswer(
        (_) async => const LiveStackingResult(
          width: 4,
          height: 4,
          data: <int>[],
          stats: LiveStackingStats(stackedFrameCount: 12),
        ),
      );
      container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          liveStackingServiceProvider.overrideWith(
            (ref) => LiveStackingService(ref, saveFitsMaster: fakeSaveFits),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    test('a remote stack cannot be written as FITS from the client', () async {
      final service = container.read(liveStackingServiceProvider);

      await expectLater(
        service.saveMaster(filePath: '/tmp/stack_master.fits'),
        throwsA(
          isA<LiveStackingMasterFormatUnsupported>()
              .having((e) => e.requestedExtension, 'extension', '.fits')
              .having((e) => e.reason, 'reason', contains('imaging host')),
        ),
      );
      // The refusal happens before anything is read out of the stacker, so a
      // wrong-format request cannot disturb a running session.
      verifyNever(() => backend.stackingGetResult());
      expect(fitsRequests, isEmpty);
    });
  });

  test('the refusal explains what is lost, not just that it failed', () {
    const error = LiveStackingMasterFormatUnsupported(
      '.tif',
      reason: 'the live stacker writes a FITS master or a PNG render',
    );
    final message = error.toString();
    expect(message, contains('.tif'));
    expect(message, contains('FITS master'));
  });
}
