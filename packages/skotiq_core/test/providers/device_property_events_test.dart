import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/skotiq_core.dart';
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
/// whoever made it (`state_events.rs`). These are the slave-side checks that
/// the events in that shape land in the same providers the host's own
/// `DeviceService` writes, so a slave and its host show one state.
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

  Future<void> mirror(SkotiqEvent event) =>
      applyRemoteSyncEvent(container, event, networkBackend: backend);

  test('a host filter move moves the slave wheel', () async {
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

  test('a host focuser move moves the slave focuser', () async {
    await mirror(_equipment('FocuserMoveStarted', {'target_position': 26000}));
    expect(container.read(focuserStateProvider).isMoving, isTrue);

    await mirror(_equipment('FocuserMoveCompleted', {'position': 25995}));

    final focuser = container.read(focuserStateProvider);
    expect(focuser.isMoving, isFalse);
    expect(focuser.position, 25995);
  });

  test('camera gain, offset and binning reach the slave', () async {
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

  test('renamed slots reach the slave', () async {
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
}
