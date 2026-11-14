// The profile's guide camera is a second camera the built-in guider uses. Its
// connect, disconnect and error events must never take or clear the imaging
// camera's slot: on the simulator rig the Equipment screen showed the guide
// camera as "the camera" and reported the imaging camera as not connected.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/models/equipment_profile_model.dart';

import '../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/providers/device_service_providers.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late ProviderContainer container;
  late StreamController<SkotiqEvent> events;

  setUpAll(registerMocktailFallbackValues);

  setUp(() {
    final backend = MockBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 1,
            name: 'Sim Rig',
            cameraId: 'sim_camera_1',
            guiderId: 'native:builtin_guider:multi_star',
            guideCameraId: 'sim_camera_2',
          ),
        ),
      ],
    );
    container.read(deviceServiceProvider);
    container.read(cameraStateProvider.notifier)
      ..setConnecting('sim_camera_1', 'Simulated Camera')
      ..setConnected();
  });

  tearDown(() {
    events.close();
    container.dispose();
  });

  SkotiqEvent event(String type, {Map<String, dynamic> extra = const {}}) =>
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: type,
        data: {'device_type': 'camera', 'device_id': 'sim_camera_2', ...extra},
      );

  test(
    'the guide camera connecting leaves the imaging camera in its slot',
    () async {
      events
        ..add(event('Connecting'))
        ..add(event('Connected'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final camera = container.read(cameraStateProvider);
      expect(camera.deviceId, 'sim_camera_1');
      expect(camera.connectionState, DeviceConnectionState.connected);
    },
  );

  test('the guide camera disconnecting or failing does not touch it', () async {
    events
      ..add(event('Disconnected'))
      ..add(event('Error', extra: {'message': 'USB transfer failed'}));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final camera = container.read(cameraStateProvider);
    expect(camera.deviceId, 'sim_camera_1');
    expect(camera.connectionState, DeviceConnectionState.connected);
  });

  test('isProfileGuideCamera never names the imaging camera', () {
    const profile = EquipmentProfileModel(
      name: 'p',
      cameraId: 'cam',
      guideCameraId: 'cam',
    );
    expect(isProfileGuideCamera(profile, 'cam'), isFalse);
    expect(isProfileGuideCamera(null, 'cam'), isFalse);
  });
}
