// The pixel pitch is what turns a frame into a measurable image.
//
// Every FITS this path wrote carried FOCALLEN and APTDIA but no XPIXSZ/YPIXSZ,
// because the header builder passed `pixelSizeX: null` with the note "Pixel
// size not stored in profile yet" — true of the profile table, and the wrong
// reason to write nothing when the connected camera reports the value. Without
// the pitch, ASTAP, PixInsight and AstroBin cannot derive the plate scale from
// the file alone, even though the app shows that scale on the Framing screen.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/capture_preview_loader.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';
import 'package:skotiq_core/src/services/science/science_processing_service.dart';

import '../mocks/mock_backend.dart';

class _NoOpScienceProcessingService extends ScienceProcessingService {
  _NoOpScienceProcessingService(super.ref);

  @override
  Future<void> processCapturedFrame({
    required String imagePath,
    String? deviceId,
    int? capturedImageId,
    int? sessionId,
  }) async {}
}

class _NoOpCapturePreviewPublisher extends CapturePreviewPublisher {
  @override
  void publish(dynamic ref, CapturedImageData preview, String deviceId) {}
}

class _FakeAppSettings extends AppSettingsNotifier {
  _FakeAppSettings(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

CapturedImageResult _capturedImage() {
  return CapturedImageResult(
    width: 8,
    height: 8,
    displayData: List<int>.filled(8 * 8 * 4, 128),
    histogram: List<int>.filled(256, 1),
    stats: const ImageStatsResult(
      min: 100.0,
      max: 20000.0,
      mean: 5000.0,
      median: 4800.0,
      stdDev: 500.0,
      hfr: 2.5,
      starCount: 80,
    ),
    timestamp: '2026-01-15T22:30:00Z',
    exposureTime: 5.0,
  );
}

CameraCapabilities _caps({double? pixelSizeX, double? pixelSizeY}) {
  return CameraCapabilities(
    maxWidth: 4144,
    maxHeight: 2822,
    bitDepth: 16,
    pixelSizeX: pixelSizeX,
    pixelSizeY: pixelSizeY,
  );
}

void main() {
  late MockBackend backend;
  late StreamController<SkotiqEvent> events;
  late Directory outputDir;
  late List<FitsWriteHeader> writtenHeaders;

  setUpAll(() {
    registerMocktailFallbackValues();
    registerFallbackValue(
      const FitsWriteHeader(
        exposureTime: 1.0,
        captureTimestamp: '2026-01-01T00:00:00Z',
        frameType: 'Light',
      ),
    );
  });

  setUp(() {
    outputDir = Directory.systemTemp.createTempSync('ns_pixel_size');
    writtenHeaders = <FitsWriteHeader>[];
    backend = MockBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.cameraSetReadoutMode(any(), any()),
    ).thenAnswer((_) async {});
    when(
      () => backend.cameraStartExposure(
        deviceId: any(named: 'deviceId'),
        exposureTime: any(named: 'exposureTime'),
        frameType: any(named: 'frameType'),
        gain: any(named: 'gain'),
        offset: any(named: 'offset'),
        binX: any(named: 'binX'),
        binY: any(named: 'binY'),
      ),
    ).thenAnswer((_) async {
      events.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ExposureComplete',
          data: const {},
        ),
      );
    });
    when(
      () => backend.cameraGetLastImage(any()),
    ).thenAnswer((_) async => _capturedImage());
    when(
      () => backend.saveFitsFromLastCapture(
        deviceId: any(named: 'deviceId'),
        filePath: any(named: 'filePath'),
        headerData: any(named: 'headerData'),
      ),
    ).thenAnswer((invocation) async {
      writtenHeaders.add(
        invocation.namedArguments[#headerData] as FitsWriteHeader,
      );
      final path = invocation.namedArguments[#filePath] as String;
      File(path).writeAsBytesSync(const <int>[0]);
    });
  });

  tearDown(() {
    events.close();
    if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier.setConnecting('cam-1', 'ASI2600MM');
          notifier.setConnected();
          return notifier;
        }),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettings(
            AppSettingsState(imageOutputPath: outputDir.path),
          ),
        ),
        capturePreviewPublisherProvider.overrideWithValue(
          _NoOpCapturePreviewPublisher(),
        ),
        scienceProcessingServiceProvider.overrideWith(
          (ref) => _NoOpScienceProcessingService(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> capture(ProviderContainer container, {int binning = 1}) async {
    await container.read(appSettingsProvider.future);
    await container
        .read(imagingServiceProvider)
        .captureImage(
          settings: ExposureSettings(
            exposureTime: 1,
            gain: 100,
            offset: 10,
            binningX: binning,
            binningY: binning,
          ),
        );
  }

  test('the FITS carries the camera-reported pixel pitch', () async {
    when(
      () => backend.getCameraCapabilities(any()),
    ).thenAnswer((_) async => _caps(pixelSizeX: 3.76, pixelSizeY: 3.76));

    final container = buildContainer();
    await capture(container);

    expect(writtenHeaders, hasLength(1));
    expect(writtenHeaders.single.pixelSizeX, 3.76);
    expect(writtenHeaders.single.pixelSizeY, 3.76);
  });

  test('the pitch is the UNBINNED sensor value — Rust scales it', () async {
    // The Rust writer emits XPIXSZ = pixel_size_x * XBINNING, so pre-scaling
    // here would double-count the binning factor.
    when(
      () => backend.getCameraCapabilities(any()),
    ).thenAnswer((_) async => _caps(pixelSizeX: 3.76, pixelSizeY: 3.76));

    final container = buildContainer();
    await capture(container, binning: 2);

    expect(writtenHeaders.single.binX, 2);
    expect(writtenHeaders.single.pixelSizeX, 3.76);
  });

  test('a driver that reports no pitch gets no fabricated card', () async {
    when(
      () => backend.getCameraCapabilities(any()),
    ).thenAnswer((_) async => _caps(pixelSizeX: 0.0, pixelSizeY: null));

    final container = buildContainer();
    await capture(container);

    expect(writtenHeaders.single.pixelSizeX, isNull);
    expect(writtenHeaders.single.pixelSizeY, isNull);
  });

  test('a camera with no capability report still saves the frame', () async {
    when(
      () => backend.getCameraCapabilities(any()),
    ).thenAnswer((_) async => null);

    final container = buildContainer();
    await capture(container);

    expect(
      writtenHeaders,
      hasLength(1),
      reason: 'a missing header card must not fail the capture',
    );
    expect(writtenHeaders.single.pixelSizeX, isNull);
    expect(writtenHeaders.single.pixelSizeY, isNull);
  });
}
