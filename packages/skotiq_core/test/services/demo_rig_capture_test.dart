// A capture taken through the app's own imaging service on the demo rig: the
// demo camera's events, frame and FITS file are what the capture pipeline
// expects from a real camera.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/demo_backend/demo_backend.dart';
import 'package:skotiq_core/src/backend/demo_backend/demo_star_field.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/capture_preview_loader_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/imaging_service_providers.dart';
import 'package:skotiq_core/src/providers/science/science_processing_service_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/capture_preview_loader.dart';
import 'package:skotiq_core/src/services/science/science_processing_service.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';

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
  late Directory scratch;
  late Directory outputDir;
  late DemoBackend backend;

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('demo_rig_scratch_');
    outputDir = Directory.systemTemp.createTempSync('demo_rig_output_');
    backend = DemoBackend(
      latitudeDeg: 40,
      longitudeDeg: -105,
      renderFrame: (request) async => renderDemoFrame(request),
      scratchDirectory: () async => scratch,
      cameraWidth: 96,
      cameraHeight: 64,
    );
    await backend.connectDevice(DeviceType.camera, DemoDeviceIds.camera);
  });

  tearDown(() {
    backend.dispose();
    for (final dir in [scratch, outputDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  Future<ProviderContainer> buildContainer(String imageOutputPath) async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier.setConnecting(DemoDeviceIds.camera, 'Demo Camera');
          notifier.setConnected();
          return notifier;
        }),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettings(
            AppSettingsState(imageOutputPath: imageOutputPath),
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
    return container;
  }

  const settings = ExposureSettings(exposureTime: 0.5, gain: 120, offset: 12);

  test('a capture with no output folder saves a scratch FITS frame', () async {
    final container = await buildContainer('');
    final captured = await container
        .read(imagingServiceProvider)
        .captureImage(settings: settings);
    expect(captured, isNotNull);
    expect(captured!.width, 96);
    expect(captured.height, 64);
    expect(captured.stats.starCount, greaterThan(0));
    final path = captured.filePath;
    expect(path, isNotNull);
    expect(path!.startsWith(scratch.path), isTrue);
    final bytes = File(path).readAsBytesSync();
    expect(String.fromCharCodes(bytes.take(9)), 'SIMPLE  =');
  });

  test('a capture with an output folder writes its FITS file there', () async {
    final container = await buildContainer(outputDir.path);
    final captured = await container
        .read(imagingServiceProvider)
        .captureImage(settings: settings);
    expect(captured, isNotNull);
    final path = captured!.filePath;
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
    expect(path.startsWith(outputDir.path), isTrue);
  });
}
