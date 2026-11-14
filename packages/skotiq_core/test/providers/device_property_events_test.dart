import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/providers/equipment/device_property_events.dart';
import '../harness/in_memory_database.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

SkotiqEvent _equipment(String type, Map<String, dynamic> data) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.equipment,
  eventType: type,
  data: data,
);

Map<String, dynamic> _property(
  String deviceType,
  String deviceId,
  String property,
  String value,
) => {
  'device_type': deviceType,
  'device_id': deviceId,
  'property': property,
  'value': value,
};

/// The host's native `DeviceManager` publishes every device state change
/// whoever made it (`state_events.rs`). These check that the events in that
/// shape land in the device slots through the appliers the host's
/// `DeviceService` uses; a linked client takes the slots from the host's
/// device channels.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NetworkBackend backend;
  late ProviderContainer container;

  setUp(() {
    backend = NetworkBackend(serverHost: '127.0.0.1', serverPort: 8080);
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    container.read(cameraStateProvider.notifier)
      ..setConnecting('sim_camera_1', 'Simulated Camera')
      ..setConnected();
    container.read(filterWheelStateProvider.notifier)
      ..setConnecting('sim_filterwheel_1', 'Simulated Filter Wheel')
      ..setConnected(filterNames: const ['L', 'R', 'G', 'B']);
    container.read(focuserStateProvider.notifier)
      ..setConnecting('sim_focuser_1')
      ..setConnected();
  });

  tearDown(() {
    container.dispose();
    backend.dispose();
  });

  // As the host's `DeviceService` applies an equipment event.
  Future<void> mirror(SkotiqEvent event) async {
    switch (event.eventType) {
      case 'PropertyChanged':
        applyDevicePropertyChange(container, event.data);
      case 'CameraSettingsChanged':
        applyCameraSettings(container, event.data);
      default:
        applyDeviceStateEvent(container, event.eventType, event.data);
    }
  }

  test('a host filter move moves the wheel', () async {
    await mirror(
      _equipment('FilterChanging', {
        'from_position': 1,
        'to_position': 3,
        'filter_name': 'B',
        'from_filter_name': 'R',
      }),
    );
    expect(container.read(filterWheelStateProvider).isMoving, isTrue);

    await mirror(
      _equipment('FilterChanged', {'position': 3, 'filter_name': 'B'}),
    );

    final wheel = container.read(filterWheelStateProvider);
    expect(wheel.isMoving, isFalse);
    expect(wheel.currentPosition, 3);
  });

  test('a host focuser move moves the focuser', () async {
    await mirror(_equipment('FocuserMoveStarted', {'target_position': 26000}));
    expect(container.read(focuserStateProvider).isMoving, isTrue);

    await mirror(_equipment('FocuserMoveCompleted', {'position': 25995}));

    final focuser = container.read(focuserStateProvider);
    expect(focuser.isMoving, isFalse);
    expect(focuser.position, 25995);
  });

  test('camera gain, offset and binning reach the cards', () async {
    await mirror(
      _equipment(
        'PropertyChanged',
        _property('Camera', 'sim_camera_1', 'Gain', '139'),
      ),
    );
    await mirror(
      _equipment(
        'PropertyChanged',
        _property('Camera', 'sim_camera_1', 'Offset', '21'),
      ),
    );
    await mirror(
      _equipment(
        'PropertyChanged',
        _property('Camera', 'sim_camera_1', 'Binning', '2x2'),
      ),
    );

    final camera = container.read(cameraStateProvider);
    expect(camera.gain, 139);
    expect(camera.offset, 21);
    expect(camera.binning, '2x2');
  });

  test('the camera\'s full settings reach the card in one event', () async {
    await mirror(
      _equipment('CameraSettingsChanged', {
        'device_id': 'sim_camera_1',
        'gain': 139,
        'offset': 21,
        'bin_x': 2,
        'bin_y': 2,
      }),
    );

    final camera = container.read(cameraStateProvider);
    expect(camera.gain, 139);
    expect(camera.offset, 21);
    expect(camera.binning, '2x2');
  });

  test('a guide camera setting leaves the imaging camera alone', () async {
    container.read(cameraStateProvider.notifier).applySetting(gain: 100);

    await mirror(
      _equipment(
        'PropertyChanged',
        _property('Camera', 'sim_camera_2', 'Gain', '300'),
      ),
    );

    expect(container.read(cameraStateProvider).gain, 100);
  });

  test('renamed slots reach the cards', () async {
    await mirror(
      _equipment(
        'PropertyChanged',
        _property(
          'Filter Wheel',
          'sim_filterwheel_1',
          'FilterNames',
          '["Lum","R","G","B"]',
        ),
      ),
    );

    expect(container.read(filterWheelStateProvider).filterNames, [
      'Lum',
      'R',
      'G',
      'B',
    ]);
  });

  test('an unknown property is not applied', () {
    expect(
      applyDevicePropertyChange(
        container,
        _property('Camera', 'sim_camera_1', 'AutofocusFinished', '{}'),
      ),
      isFalse,
    );
    expect(
      applyDevicePropertyChange(
        container,
        _property('Camera', 'sim_camera_1', 'Gain', 'not a number'),
      ),
      isFalse,
    );
  });

  group('events name their device', () {
    test(
      'a guide camera\'s cooler never shows as the imaging camera\'s',
      () async {
        await mirror(
          _equipment('CameraCoolingStarted', {
            'device_id': 'sim_camera_2',
            'target_temp': -5.0,
          }),
        );
        var camera = container.read(cameraStateProvider);
        expect(camera.isCooling, isFalse);

        await mirror(
          _equipment('CameraCoolingStarted', {
            'device_id': 'sim_camera_1',
            'target_temp': -10.0,
          }),
        );
        camera = container.read(cameraStateProvider);
        expect(camera.isCooling, isTrue);
        expect(camera.targetTemp, -10.0);

        await mirror(
          _equipment('CameraWarmingStarted', {'device_id': 'sim_camera_2'}),
        );
        expect(container.read(cameraStateProvider).isCooling, isTrue);
      },
    );

    test('a second focuser, wheel or rotator leaves the slot alone', () async {
      await mirror(
        _equipment('FocuserMoveCompleted', {
          'device_id': 'other_focuser',
          'position': 1234,
        }),
      );
      await mirror(
        _equipment('FilterChanged', {
          'device_id': 'other_wheel',
          'position': 2,
        }),
      );
      expect(container.read(focuserStateProvider).position, isNot(1234));
      expect(
        container.read(filterWheelStateProvider).currentPosition,
        isNot(2),
      );

      await mirror(
        _equipment('FilterChanged', {
          'device_id': 'sim_filterwheel_1',
          'position': 2,
        }),
      );
      expect(container.read(filterWheelStateProvider).currentPosition, 2);
    });

    test('an event from a host older than the id still applies', () {
      expect(
        applyDeviceStateEvent(container, 'FocuserMoveCompleted', {
          'position': 777,
        }),
        isTrue,
      );
      expect(container.read(focuserStateProvider).position, 777);
    });
  });

  test('the camera temperature the host read reaches the card', () async {
    await mirror(
      _equipment('CameraTemperatureChanged', {
        'device_id': 'sim_camera_1',
        'temperature': -9.5,
        'coolerPower': 41.0,
      }),
    );
    var camera = container.read(cameraStateProvider);
    expect(camera.temperature, -9.5);
    expect(camera.coolerPower, 41.0);

    // Another camera's reading is not this one's.
    await mirror(
      _equipment('CameraTemperatureChanged', {
        'device_id': 'sim_camera_2',
        'temperature': 18.0,
        'coolerPower': null,
      }),
    );
    camera = container.read(cameraStateProvider);
    expect(camera.temperature, -9.5);
    expect(camera.coolerPower, 41.0);
  });

  test('an alt/az slew and an abort show on the mount at once', () {
    container.read(mountStateProvider.notifier)
      ..setConnecting('sim_mount_1')
      ..setConnected();
    expect(
      applyDevicePropertyChange(
        container,
        _property('Mount', 'sim_mount_1', 'SlewToAltAz', '60 250'),
      ),
      isTrue,
    );
    expect(container.read(mountStateProvider).isSlewing, isTrue);
    expect(
      applyDevicePropertyChange(
        container,
        _property('Mount', 'sim_mount_1', 'AbortSlew', ''),
      ),
      isTrue,
    );
    expect(container.read(mountStateProvider).isSlewing, isFalse);
    expect(
      applyDevicePropertyChange(
        container,
        _property('Mount', 'another_mount', 'Synced', '3 10'),
      ),
      isFalse,
    );
  });
}
