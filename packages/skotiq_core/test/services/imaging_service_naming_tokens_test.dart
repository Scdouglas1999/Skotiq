// `$SEQUENCE` must mean the sequence, not the target.
//
// ImagingService documents its `$VARIABLE` set as "honoured here so that
// patterns shared between the Dart and Rust capture paths behave identically",
// and the Rust generator (native/skotiq_native/imaging/src/naming.rs)
// resolves `$SEQUENCE` to `ctx.sequence`, falling back to the literal
// "Sequence". The Dart side substituted the TARGET name instead, so one pattern
// filed sequencer frames under the plan's name and manual frames of the same
// object under the object's name — in a folder labelled as a sequence.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
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
  void publish(
    dynamic ref,
    CapturedImageData preview,
    String deviceId, {
    bool loadRaw = true,
  }) {}
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

void main() {
  late MockBackend backend;
  late StreamController<SkotiqEvent> events;
  late Directory outputDir;
  late List<String> writtenPaths;

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
    outputDir = Directory.systemTemp.createTempSync('sk_naming_tokens');
    writtenPaths = <String>[];
    backend = MockBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.getCameraCapabilities(any()),
    ).thenAnswer((_) async => null);
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
    when(() => backend.cameraGetLastImage(any())).thenAnswer(
      (_) async => CapturedImageResult(
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
        exposureTime: 1.0,
      ),
    );
    when(
      () => backend.saveFitsFromLastCapture(
        deviceId: any(named: 'deviceId'),
        filePath: any(named: 'filePath'),
        headerData: any(named: 'headerData'),
      ),
    ).thenAnswer((invocation) async {
      final path = invocation.namedArguments[#filePath] as String;
      writtenPaths.add(path);
      File(path).createSync(recursive: true);
      File(path).writeAsBytesSync(const <int>[0]);
    });
  });

  tearDown(() {
    events.close();
    if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
  });

  test(
    'an ad-hoc capture does not file itself under a fake sequence',
    () async {
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          cameraStateProvider.overrideWith((ref) {
            final notifier = CameraStateNotifier(ref);
            notifier.setConnecting('cam-1', 'Test Camera');
            notifier.setConnected();
            return notifier;
          }),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettings(
              AppSettingsState(
                imageOutputPath: outputDir.path,
                fileNamingPattern: r'$SEQUENCE/$TARGET_$SEQ',
              ),
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
      await container.read(appSettingsProvider.future);

      await container
          .read(imagingServiceProvider)
          .captureImage(
            settings: const ExposureSettings(
              exposureTime: 1,
              gain: 100,
              offset: 10,
            ),
            targetName: 'M31',
          );

      expect(writtenPaths, hasLength(1));
      expect(
        p.basename(p.dirname(writtenPaths.single)),
        'Sequence',
        reason:
            'the Rust generator\'s no-sequence value; the target belongs in '
            r'$TARGET',
      );
      expect(
        p.basenameWithoutExtension(writtenPaths.single),
        'M31_0001',
        reason: r'$TARGET still resolves to the target',
      );
    },
  );
}
