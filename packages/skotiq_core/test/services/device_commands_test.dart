import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// Records the DeviceService commands the shared path sends.
class _RecordingDeviceService implements DeviceService {
  final calls = <String>[];

  @override
  Future<void> setFilterWheelPosition(int position) async =>
      calls.add('setFilterWheelPosition $position');

  @override
  Future<void> setFilterWheelNames(List<String> names) async =>
      calls.add('setFilterWheelNames ${names.join(',')}');

  @override
  Future<void> moveFocuserTo(int position) async =>
      calls.add('moveFocuserTo $position');

  @override
  Future<void> moveRotatorTo(double angle) async =>
      calls.add('moveRotatorTo $angle');

  @override
  void cancelWarmCamera({bool restorePriorSetting = true}) =>
      calls.add('cancelWarmCamera $restorePriorSetting');

  @override
  Future<void> setCameraCooling({
    required bool enabled,
    double? targetTemp,
  }) async => calls.add('setCameraCooling $enabled $targetTemp');

  @override
  Future<void> refreshDomeStatus() async => calls.add('refreshDomeStatus');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A command for the device in the host's slot takes the host UI's
/// DeviceService path (focus offset, checks, cooling goal); any other device
/// goes to the backend.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockBackend backend;
  late _RecordingDeviceService service;
  late ProviderContainer container;

  setUp(() {
    backend = MockBackend();
    service = _RecordingDeviceService();
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        deviceServiceProvider.overrideWithValue(service),
      ],
    );
    container.read(filterWheelStateProvider.notifier)
      ..setConnecting('wheel_1', 'Wheel')
      ..setConnected(filterNames: const ['L', 'R', 'Ha']);
    container.read(focuserStateProvider.notifier)
      ..setConnecting('focuser_1')
      ..setConnected();
    container.read(cameraStateProvider.notifier)
      ..setConnecting('camera_1', 'Camera')
      ..setConnected();
    when(() => backend.getFilterWheelStatus('wheel_1')).thenAnswer(
      (_) async => const FilterWheelStatus(
        connected: true,
        position: 0,
        moving: false,
        filterCount: 3,
        filterNames: ['L', 'R', 'Ha'],
      ),
    );
    when(
      () => backend.filterWheelSetByName(any(), any()),
    ).thenAnswer((_) async {});
    when(() => backend.focuserMoveTo(any(), any())).thenAnswer((_) async {});
    when(
      () => backend.cameraSetCooling(
        deviceId: any(named: 'deviceId'),
        enabled: any(named: 'enabled'),
        targetTemp: any(named: 'targetTemp'),
      ),
    ).thenAnswer((_) async {});
    when(() => backend.rotatorMoveTo(any(), any())).thenAnswer((_) async {});
    when(() => backend.domePark(any())).thenAnswer((_) async {});
  });

  tearDown(() => container.dispose());

  DeviceCommands commands() => container.read(deviceCommandsProvider);

  test('a filter asked for by name moves like one asked for by slot', () async {
    await commands().filterWheelSetByName('wheel_1', 'Ha');
    expect(service.calls, ['setFilterWheelPosition 2']);
    verifyNever(() => backend.filterWheelSetByName(any(), any()));
  });

  test('a name the filter-name rule matches moves the slot wheel, focus '
      'offset included', () async {
    await commands().filterWheelSetByName('wheel_1', 'H-alpha');
    await commands().filterWheelSetByName('wheel_1', 'lum');
    expect(service.calls, [
      'setFilterWheelPosition 2',
      'setFilterWheelPosition 0',
    ]);
    verifyNever(() => backend.filterWheelSetByName(any(), any()));
  });

  test(
    'another wheel, or a name the wheel lacks, goes to the backend',
    () async {
      await commands().filterWheelSetByName('wheel_2', 'Ha');
      await commands().filterWheelSetByName('wheel_1', 'OIII');
      expect(service.calls, isEmpty);
      verify(() => backend.filterWheelSetByName('wheel_2', 'Ha')).called(1);
      verify(() => backend.filterWheelSetByName('wheel_1', 'OIII')).called(1);
    },
  );

  test(
    'the slot focuser moves through DeviceService, another one not',
    () async {
      await commands().focuserMoveTo('focuser_1', 26000);
      await commands().focuserMoveTo('focuser_2', 100);
      expect(service.calls, ['moveFocuserTo 26000']);
      verify(() => backend.focuserMoveTo('focuser_2', 100)).called(1);
      verifyNever(() => backend.focuserMoveTo('focuser_1', any()));
    },
  );

  test('cooling the slot camera records the goal; a guide camera does not '
      'touch the imaging camera\'s warm-up', () async {
    await commands().cameraSetCooling(
      'camera_1',
      enabled: true,
      targetTemp: -15,
    );
    await commands().cameraSetCooling(
      'guide_camera',
      enabled: true,
      targetTemp: -5,
    );
    expect(service.calls, [
      'cancelWarmCamera false',
      'setCameraCooling true -15.0',
    ]);
    verify(
      () => backend.cameraSetCooling(
        deviceId: 'guide_camera',
        enabled: true,
        targetTemp: -5,
      ),
    ).called(1);
  });

  test('a slot nobody connected is never created by asking', () async {
    await commands().rotatorMoveTo('rotator_1', 90);
    expect(container.exists(rotatorStateProvider), isFalse);
    verify(() => backend.rotatorMoveTo('rotator_1', 90)).called(1);
  });

  test('a dome command re-reads the slot dome', () async {
    container.read(domeStateProvider.notifier)
      ..setConnecting('dome_1')
      ..setConnected();
    await commands().domePark('dome_1');
    await commands().domePark('dome_2');
    expect(service.calls, ['refreshDomeStatus']);
    verify(() => backend.domePark('dome_1')).called(1);
    verify(() => backend.domePark('dome_2')).called(1);
  });
}
