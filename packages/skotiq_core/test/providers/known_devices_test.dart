// Equipment > Devices read "DISCOVERED DEVICES 0 found · Never scanned" with
// five devices connected: the drawer listed only the last scan, and a rig that
// connects from its profile never scans. The list is every device the host
// knows about.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/models/backend/device_info.dart';
import 'package:skotiq_core/src/models/equipment/discovery_state.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/equipment/known_devices.dart';
import 'package:skotiq_core/src/models/equipment/unified_device.dart';
import 'package:skotiq_core/src/models/equipment_profile_model.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/unified_discovery_provider.dart';

const _profile = EquipmentProfileModel(
  id: 1,
  name: 'Sim Rig',
  cameraId: 'sim_camera_1',
  cameraName: 'Simulated Camera',
  mountId: 'sim_mount_1',
  focuserId: 'sim_focuser_1',
  filterWheelId: 'sim_filterwheel_1',
  guiderId: 'native:builtin_guider:multi_star',
);

DeviceInfo _info(
  String id,
  String name,
  DeviceType type, [
  DriverType driver = DriverType.simulator,
]) => DeviceInfo(
  id: id,
  name: name,
  deviceType: type,
  driverType: driver,
  description: '',
  driverVersion: '',
);

UnifiedDevice _scanned(DeviceInfo info) => UnifiedDevice(
  canonicalName: info.id,
  displayName: info.name,
  type: info.deviceType,
  availableBackends: {info.driverType: info},
);

SlotDevice _slot(DeviceConnectionState state, String? id, [String? name]) =>
    (state: state, id: id, name: name, error: null);

Map<DeviceType, SlotDevice> _connected(EquipmentProfileModel profile) => {
  for (final type in DeviceType.values)
    if (profile.deviceIdFor(type) case final id?)
      type: _slot(DeviceConnectionState.connected, id),
};

KnownDevice _only(KnownDevices known, String id) =>
    known.devices.singleWhere((d) => d.id == id);

void main() {
  group('buildKnownDevices', () {
    test('a rig connected from its profile lists every device, no scan', () {
      final known = buildKnownDevices(
        slots: _connected(_profile),
        profile: _profile,
        scanned: const [],
        lastScanAt: null,
      );

      expect(known.devices.map((d) => d.id), [
        'sim_camera_1',
        'sim_mount_1',
        'sim_focuser_1',
        'sim_filterwheel_1',
        'native:builtin_guider:multi_star',
      ]);
      expect(known.connected, 5);
      expect(known.lastScanAt, isNull);
      expect(known.devices.every((d) => d.inProfile && !d.foundByScan), isTrue);
      expect(_only(known, 'sim_camera_1').name, 'Simulated Camera');
      expect(_only(known, 'sim_mount_1').name, 'Simulated Mount');
      expect(
        _only(known, 'sim_mount_1').device.activeBackend,
        DriverType.simulator,
      );
    });

    test('a scan alone lists what it found, none connected', () {
      final at = DateTime.utc(2026, 11, 16, 2, 52);
      final known = buildKnownDevices(
        slots: const {},
        profile: null,
        scanned: [
          _scanned(
            _info('sim_camera_1', 'Simulated Camera', DeviceType.camera),
          ),
          _scanned(_info('sim_mount_1', 'Simulated Mount', DeviceType.mount)),
        ],
        lastScanAt: at,
      );

      expect(known.devices.map((d) => d.id), ['sim_camera_1', 'sim_mount_1']);
      expect(known.connected, 0);
      expect(known.lastScanAt, at);
      expect(
        known.devices.every(
          (d) =>
              d.foundByScan &&
              !d.inProfile &&
              d.state == DeviceConnectionState.disconnected,
        ),
        isTrue,
      );
    });

    test('a device both connected and scanned is listed once, by the id it '
        'is connected under', () {
      final zwoNative = _info(
        'native:zwo:0',
        'ZWO ASI1600MM Pro',
        DeviceType.camera,
        DriverType.native,
      );
      final zwoAscom = _info(
        'ascom:ASCOM.ASICamera2.Camera',
        'ASI Camera (1)',
        DeviceType.camera,
        DriverType.ascom,
      );
      final known = buildKnownDevices(
        slots: {
          DeviceType.camera: _slot(
            DeviceConnectionState.connected,
            'ascom:ASCOM.ASICamera2.Camera',
            'ASI Camera (1)',
          ),
        },
        profile: const EquipmentProfileModel(
          id: 1,
          name: 'Rig',
          cameraId: 'ascom:ASCOM.ASICamera2.Camera',
          mountId: 'sim_mount_1',
        ),
        scanned: [
          UnifiedDevice(
            canonicalName: 'zwo asi1600mm pro',
            displayName: 'ZWO ASI1600MM Pro',
            type: DeviceType.camera,
            availableBackends: {
              DriverType.native: zwoNative,
              DriverType.ascom: zwoAscom,
            },
          ),
          _scanned(
            _info('sim_focuser_1', 'Simulated Focuser', DeviceType.focuser),
          ),
        ],
        lastScanAt: DateTime.utc(2026, 11, 16),
      );

      expect(known.devices.map((d) => d.id), [
        'ascom:ASCOM.ASICamera2.Camera',
        'sim_mount_1',
        'sim_focuser_1',
      ]);
      final camera = known.devices.first;
      expect(camera.name, 'ZWO ASI1600MM Pro');
      expect(camera.isConnected, isTrue);
      expect(camera.inProfile, isTrue);
      expect(camera.foundByScan, isTrue);
      expect(camera.device.activeBackend, DriverType.ascom);
      final mount = _only(known, 'sim_mount_1');
      expect(
        mount.inProfile && !mount.foundByScan && !mount.isConnected,
        isTrue,
      );
      final focuser = _only(known, 'sim_focuser_1');
      expect(focuser.foundByScan && !focuser.inProfile, isTrue);
      expect(known.connected, 1);
    });

    test('after a disconnect the profile device stays, not connected', () {
      final slots = _connected(_profile)
        ..[DeviceType.mount] = _slot(DeviceConnectionState.disconnected, null);
      final known = buildKnownDevices(
        slots: slots,
        profile: _profile,
        scanned: const [],
        lastScanAt: null,
      );

      expect(known.devices, hasLength(5));
      expect(known.connected, 4);
      final mount = _only(known, 'sim_mount_1');
      expect(mount.state, DeviceConnectionState.disconnected);
      expect(mount.inProfile, isTrue);
    });

    test("a built-in guider's guide camera reads connected from the "
        'registry', () {
      final known = buildKnownDevices(
        slots: _connected(_profile),
        connected: [
          _info('sim_camera_2', 'Simulated Guide Camera', DeviceType.camera),
        ],
        profile: _profile.copyWith(guideCameraId: 'sim_camera_2'),
        scanned: [
          _scanned(
            _info('sim_camera_2', 'Simulated Guide Camera', DeviceType.camera),
          ),
        ],
        lastScanAt: DateTime.utc(2026, 11, 16),
      );
      final guideCamera = _only(known, 'sim_camera_2');
      expect(guideCamera.isConnected, isTrue);
      expect(guideCamera.inProfile, isTrue);
      expect(known.devices, hasLength(6));
    });

    test('a failed connect is listed with why', () {
      final known = buildKnownDevices(
        slots: {
          DeviceType.mount: (
            state: DeviceConnectionState.error,
            id: 'sim_mount_1',
            name: null,
            error: 'Port is busy',
          ),
        },
        profile: _profile,
        scanned: const [],
        lastScanAt: null,
      );
      final mount = _only(known, 'sim_mount_1');
      expect(mount.state, DeviceConnectionState.error);
      expect(mount.error, 'Port is busy');
      expect(known.devices.where((d) => d.id == 'sim_mount_1'), hasLength(1));
    });

    test('a device connected outside the profile is listed beside the '
        "profile's own", () {
      final known = buildKnownDevices(
        slots: {
          DeviceType.camera: _slot(
            DeviceConnectionState.connected,
            'sim_camera_2',
            'Simulated Guide Camera',
          ),
        },
        profile: _profile,
        scanned: const [],
        lastScanAt: null,
      );
      final cameras = known.devices.where((d) => d.type == DeviceType.camera);
      expect(cameras.map((d) => (d.id, d.isConnected, d.inProfile)), [
        ('sim_camera_1', false, true),
        ('sim_camera_2', true, false),
      ]);
    });

    test('the wire answer reads back as the same list', () {
      final known = buildKnownDevices(
        slots: _connected(_profile),
        profile: _profile,
        scanned: [
          _scanned(
            _info('sim_rotator_1', 'Simulated Rotator', DeviceType.rotator),
          ),
        ],
        lastScanAt: DateTime.utc(2026, 11, 16, 2, 52),
      );
      final back = KnownDevices.fromJson(known.toJson());

      expect(back.lastScanAt!.isAtSameMomentAs(known.lastScanAt!), isTrue);
      expect(
        back.devices.map(
          (d) => (d.id, d.name, d.type, d.state, d.inProfile, d.foundByScan),
        ),
        known.devices.map(
          (d) => (d.id, d.name, d.type, d.state, d.inProfile, d.foundByScan),
        ),
      );
    });
  });

  group('hostKnownDevicesProvider', () {
    late ProviderContainer container;
    late SkotiqDatabase database;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          activeEquipmentProfileProvider.overrideWithValue(_profile),
          deviceBackendProvider.overrideWithValue(_Registry()),
          unifiedDiscoveryProvider.overrideWith(_FixedScan.new),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    Future<KnownDevices> read() =>
        container.read(hostKnownDevicesProvider.future);

    test('follows the slots: connected, then disconnected', () async {
      expect((await read()).connected, 0);

      container
          .read(cameraStateProvider.notifier)
          .state = const CameraStateSnapshot(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'sim_camera_1',
        deviceName: 'Simulated Camera',
      );
      var known = await read();
      expect(known.connected, 1);
      expect(known.devices, hasLength(5));

      container.read(cameraStateProvider.notifier).setDisconnected();
      known = await read();
      expect(known.connected, 0);
      expect(
        known.devices.map((d) => d.id),
        contains('sim_camera_1'),
        reason: 'the profile still names the camera',
      );
    });

    test('adds what the last scan found, and when it ran', () async {
      final at = DateTime(2026, 11, 15, 21, 52);
      (container.read(unifiedDiscoveryProvider.notifier) as _FixedScan).found([
        _info('sim_rotator_1', 'Simulated Rotator', DeviceType.rotator),
      ], at);
      final known = await read();
      expect(known.lastScanAt, at);
      expect(known.devices.map((d) => d.id), contains('sim_rotator_1'));
      expect(known.devices, hasLength(6));
    });
  });
}

/// The device registry, with nothing connected outside the slots.
class _Registry implements DeviceBackend {
  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedScan extends UnifiedDiscoveryNotifier {
  _FixedScan(super.ref);

  void found(List<DeviceInfo> devices, DateTime at) {
    state = UnifiedDiscoveryState(
      backendStates: {
        DriverType.simulator: BackendDiscoveryState(
          backend: DriverType.simulator,
          status: DiscoveryStatus.completed,
          devices: devices,
          completedAt: at,
        ),
      },
      rawDevices: devices,
      groupedDevices: [for (final device in devices) _scanned(device)],
    );
  }
}
