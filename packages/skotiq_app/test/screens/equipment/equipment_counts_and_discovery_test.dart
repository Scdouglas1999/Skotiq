// qa-pair QP-23: the "Add rotator, dome, flat panel, weather" tile kept
// offering a rotator with one connected. The drawer under Equipment > Devices
// read "DISCOVERED DEVICES 0 found · Never scanned" beside five connected
// devices: it listed only the last scan, and a rig that connects from its
// profile never scans.
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_app/screens/equipment/widgets/discovery_panel.dart';
import 'package:skotiq_app/screens/shell/widgets/rig_card.dart';
import 'package:flutter/widgets.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _CountingDiscovery extends UnifiedDiscoveryNotifier {
  _CountingDiscovery(super.ref);

  int scans = 0;

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async =>
      scans++;

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
      groupedDevices: [
        for (final device in devices)
          UnifiedDevice(
            canonicalName: device.id,
            displayName: device.name,
            type: device.deviceType,
            availableBackends: {device.driverType: device},
          ),
      ],
    );
  }
}

const _simRig = EquipmentProfileModel(
  id: 1,
  name: 'Sim Rig',
  cameraId: 'sim_camera_1',
  mountId: 'sim_mount_1',
  focuserId: 'sim_focuser_1',
  filterWheelId: 'sim_filterwheel_1',
  guiderId: 'native:builtin_guider:multi_star',
);

/// `SkotiqIconButton` carries its tooltip through `Semantics`, so
/// `find.byTooltip` misses it.
Finder _iconButton(String tooltip) => find.byWidgetPredicate(
      (w) => w is SkotiqIconButton && w.tooltip == tooltip,
    );

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(_iconButton('Expand'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the add tile names only equipment not yet connected', () {
    expect(
      addEquipmentLabel(
        rotator: false,
        dome: false,
        flatPanel: false,
        weather: false,
      ),
      'Add rotator, dome, flat panel, weather',
    );
    expect(
      addEquipmentLabel(
        rotator: true,
        dome: false,
        flatPanel: false,
        weather: true,
      ),
      'Add dome, flat panel',
    );
    expect(
      addEquipmentLabel(
        rotator: true,
        dome: true,
        flatPanel: true,
        weather: true,
      ),
      'Add equipment',
    );
  });

  testWidgets(
      'a rig connected from its profile lists its devices without a '
      'scan', (tester) async {
    late _CountingDiscovery discovery;
    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: DiscoveryPanel()),
      size: const Size(1600, 1200),
      settle: false,
      extraOverrides: [
        activeEquipmentProfileProvider.overrideWithValue(_simRig),
        unifiedDiscoveryProvider.overrideWith(
          (ref) => discovery = _CountingDiscovery(ref),
        ),
      ],
    );
    for (final type in DeviceType.values) {
      final id = _simRig.deviceIdFor(type);
      if (id == null) continue;
      handle.container.read(type.slot.notifier)
        ..setConnecting(id)
        ..setConnected();
    }
    await tester.pump();
    await _expand(tester);

    expect(find.text('KNOWN DEVICES'), findsOneWidget);
    expect(find.text('5 devices'), findsOneWidget);
    expect(find.textContaining('found'), findsNothing);
    expect(find.textContaining('Never scanned'), findsNothing);
    expect(find.text('Simulated Mount'), findsOneWidget);
    expect(
        find.textContaining('Connected · Sim · In profile'), findsNWidgets(4));
    expect(discovery.scans, 0, reason: 'listing the rig must not scan');

    // After a disconnect the mount is still a device the app knows.
    handle.container.read(mountStateProvider.notifier).setDisconnected();
    await tester.pump();
    await tester.pump();
    expect(find.text('5 devices'), findsOneWidget);
    expect(find.text('Simulated Mount'), findsOneWidget);
    expect(find.textContaining('Not connected · Sim · In profile'),
        findsOneWidget);

    resetAllEquipmentStateNotifiers(handle.container);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('after a scan the drawer adds what it found and when it ran',
      (tester) async {
    late _CountingDiscovery discovery;
    await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: DiscoveryPanel()),
      size: const Size(1600, 1200),
      settle: false,
      extraOverrides: [
        unifiedDiscoveryProvider.overrideWith(
          (ref) => discovery = _CountingDiscovery(ref),
        ),
      ],
    );
    await tester.pump();
    final at = DateTime.now();
    discovery.found(const [
      DeviceInfo(
        id: 'sim_rotator_1',
        name: 'Simulated Rotator',
        deviceType: DeviceType.rotator,
        driverType: DriverType.simulator,
        description: '',
        driverVersion: '',
      ),
    ], at);
    await tester.pump();
    await _expand(tester);

    expect(
      find.text('1 device · Last scan ${ClockFormat.hm(at)}'),
      findsOneWidget,
    );
    expect(find.text('Simulated Rotator'), findsOneWidget);
  });

  testWidgets("a linked client lists the host's devices without scanning",
      (tester) async {
    final host = _MockNetworkBackend();
    final lastScanAt = DateTime.now();
    when(() => host.knownDevices()).thenAnswer(
      (_) async => KnownDevices.fromJson({
        'devices': const [
          {
            'id': 'sim_camera_1',
            'name': 'Simulated Camera',
            'deviceType': 'camera',
            'driverType': 'simulator',
            'state': 'connected',
            'inProfile': true,
            'foundByScan': false,
          },
          {
            'id': 'sim_mount_1',
            'name': 'Simulated Mount',
            'deviceType': 'mount',
            'driverType': 'simulator',
            'state': 'disconnected',
            'inProfile': true,
            'foundByScan': true,
          },
        ],
        'lastScanAt': lastScanAt.toUtc().toIso8601String(),
      }),
    );
    late _CountingDiscovery discovery;
    await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: DiscoveryPanel()),
      size: const Size(1600, 1200),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, host)),
        unifiedDiscoveryProvider.overrideWith((ref) {
          return discovery = _CountingDiscovery(ref);
        }),
      ],
    );
    await tester.pump();
    await tester.pump();
    await _expand(tester);

    expect(
      find.text('2 devices · Last scan ${ClockFormat.hm(lastScanAt)}'),
      findsOneWidget,
    );
    expect(find.text('Simulated Mount'), findsOneWidget);
    expect(discovery.scans, 0,
        reason: 'opening the list must not scan the host');
  });

  testWidgets('before any scan the drawer states no scan time', (tester) async {
    await pumpAppScreen(
      tester,
      const DiscoveryPanel(),
      settle: false,
      extraOverrides: [
        unifiedDiscoveryProvider.overrideWith(_CountingDiscovery.new),
      ],
    );
    await tester.pump();
    expect(find.textContaining('Last scan'), findsNothing);
    expect(find.textContaining('Never scanned'), findsNothing);
    expect(find.text('KNOWN DEVICES'), findsOneWidget);
  });

  // The rail's rig card listed no rotator, so with one connected it read one
  // device fewer than the Equipment screen.
  testWidgets('the rig card counts a connected rotator', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Column(mainAxisSize: MainAxisSize.min, children: [
        RigCard(isExpanded: false),
      ]),
      size: const Size(2600, 900),
      settle: false,
    );
    final rotator = handle.container.read(rotatorStateProvider.notifier);
    rotator.setConnecting('sim_rotator_1', 'Simulated Rotator');
    rotator.setConnected();
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp(r'Equipment: 1 connected')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // Collapsed, the card read 0/4 after Disconnect all beside a profile block
  // that said "5 devices": it only listed the filter wheel while connected.
  testWidgets('the rig card counts the devices the profile assigns',
      (tester) async {
    final semantics = tester.ensureSemantics();
    const profile = EquipmentProfileModel(
      id: 1,
      name: 'Sim Rig',
      cameraId: 'sim_camera_1',
      mountId: 'sim_mount_1',
      focuserId: 'sim_focuser_1',
      filterWheelId: 'sim_filterwheel_1',
      guiderId: 'native:builtin_guider:multi_star',
    );
    final handle = await pumpAppScreen(
      tester,
      const Column(mainAxisSize: MainAxisSize.min, children: [
        RigCard(isExpanded: false),
      ]),
      size: const Size(2600, 900),
      settle: false,
      extraOverrides: [
        activeEquipmentProfileProvider.overrideWithValue(profile),
      ],
    );
    await tester.pump();
    expect(
      find.bySemanticsLabel('Equipment: 0 connected, 5 disconnected'),
      findsOneWidget,
    );
    expect(find.text('0/5'), findsOneWidget);
    expect(handle.container.read(rigDevicesProvider).assigned.length, 5);

    for (final type in DeviceType.values) {
      final id = profile.deviceIdFor(type);
      if (id == null) continue;
      handle.container.read(type.slot.notifier)
        ..setConnecting(id)
        ..setConnected();
    }
    await tester.pump();
    expect(find.text('5/5'), findsOneWidget);

    // The list beside the rail names the filter wheel while it is down.
    handle.container.read(filterWheelStateProvider.notifier).setDisconnected();
    await tester.pump();
    expect(find.text('4/5'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rig.summary')));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel('Filter wheel, disconnected'),
      findsOneWidget,
    );
    expect(find.text('No filter wheel'), findsOneWidget);

    // A connected mount polls its position; stop that before the test ends.
    resetAllEquipmentStateNotifiers(handle.container);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
