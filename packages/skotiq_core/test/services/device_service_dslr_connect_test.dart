// A DSLR or mirrorless body keeps the ISO it is set to when it connects: the
// profile's gain is not written over it, and a camera without an offset
// control is not sent one. A gain camera still takes the profile's values.

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

  test('a DSLR keeps its ISO and gets no offset at connect', () async {
    await connect(
      const CameraCapabilities(
        maxWidth: 5472,
        maxHeight: 3648,
        bitDepth: 14,
        canSetGain: true,
        isoSpeeds: [100, 200, 400, 800, 1600],
      ),
    );
    verifyNever(() => backend.cameraSetGain(any(), any()));
    verifyNever(() => backend.cameraSetOffset(any(), any()));
  });

  test('a gain camera takes the profile gain and offset at connect', () async {
    await connect(
      const CameraCapabilities(
        maxWidth: 4656,
        maxHeight: 3520,
        bitDepth: 16,
        canSetGain: true,
        canSetOffset: true,
      ),
    );
    verify(() => backend.cameraSetGain(_deviceId, 100)).called(1);
    verify(() => backend.cameraSetOffset(_deviceId, 50)).called(1);
  });

  test(
    'failed capability reads preserve the camera gain or ISO and offset',
    () async {
      await connect(null);
      verifyNever(() => backend.cameraSetGain(any(), any()));
      verifyNever(() => backend.cameraSetOffset(any(), any()));
    },
  );

  test('a fixed-gain camera is not sent profile gain or offset', () async {
    await connect(
      const CameraCapabilities(
        maxWidth: 1920,
        maxHeight: 1080,
        bitDepth: 16,
        canSetGain: false,
        canSetOffset: false,
      ),
    );
    verifyNever(() => backend.cameraSetGain(any(), any()));
    verifyNever(() => backend.cameraSetOffset(any(), any()));
  });
}
