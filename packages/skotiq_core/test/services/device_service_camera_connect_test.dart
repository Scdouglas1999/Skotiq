// Connecting a camera writes no gain or offset to it: each frame sets them,
// at what the frame names or the profile's defaults (see
// camera_frame_defaults_owner_test.dart). A DSLR or mirrorless body keeps
// the ISO it is set to.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/models/equipment_profile_model.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/device_service_providers.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';

import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

const _deviceId = 'native:gphoto2:0:757362:canon_eos_6d';

void main() {
  late MockBackend backend;
  late StreamController<SkotiqEvent> events;

  setUpAll(registerMocktailFallbackValues);

  setUp(() {
    backend = MockBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.getConnectedDevices()).thenAnswer((_) async => []);
    when(
      () => backend.cameraGetRecommendedSettings(any()),
    ).thenAnswer((_) async => const CameraRecommendedSettings(notes: ''));
    when(() => backend.discoverDevices(DeviceType.camera)).thenAnswer(
      (_) async => [
        const DeviceInfo(
          id: _deviceId,
          name: 'Canon EOS 6D',
          deviceType: DeviceType.camera,
          driverType: DriverType.native,
          description: 'gPhoto2',
          driverVersion: '2.5.34',
        ),
      ],
    );
    when(
      () => backend.connectDevice(DeviceType.camera, _deviceId),
    ).thenAnswer((_) async {});
    when(() => backend.cameraSetGain(any(), any())).thenAnswer((_) async {});
    when(() => backend.cameraSetOffset(any(), any())).thenAnswer((_) async {});
  });

  tearDown(() => events.close());

  Future<void> connect(CameraCapabilities? caps) async {
    when(() => backend.getCameraCapabilities(_deviceId)).thenAnswer((_) async {
      if (caps == null) throw StateError('Camera capability read failed');
      return caps;
    });
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Rig',
            defaultGain: 100,
            defaultOffset: 50,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(deviceServiceProvider)
        .connect(DeviceType.camera, _deviceId);
  }

  test('connect writes no gain or offset to any camera', () async {
    for (final caps in <CameraCapabilities?>[
      const CameraCapabilities(
        maxWidth: 5472,
        maxHeight: 3648,
        bitDepth: 14,
        canSetGain: true,
        isoSpeeds: [100, 200, 400, 800, 1600],
      ),
      const CameraCapabilities(
        maxWidth: 4656,
        maxHeight: 3520,
        bitDepth: 16,
        canSetGain: true,
        canSetOffset: true,
      ),
      null,
    ]) {
      await connect(caps);
      verifyNever(() => backend.cameraSetGain(any(), any()));
      verifyNever(() => backend.cameraSetOffset(any(), any()));
    }
  });
}
