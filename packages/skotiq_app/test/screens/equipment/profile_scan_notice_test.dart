// The profile check before Connect all: a profile device the last device scan
// did not list is named next to Connect all, with a way to scan again. It
// never hides or disables Connect all.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/widgets/profile_scan_notice.dart';
import 'package:skotiq_app/screens/equipment/widgets/profile_sidebar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _rig = EquipmentProfileModel(
  id: 1,
  name: 'Sim rig',
  cameraId: 'sim_camera_1',
  cameraName: 'Simulated Camera',
  mountId: 'sim_mount_1',
  mountName: 'Simulated Mount',
);

DeviceInfo _mount() => const DeviceInfo(
  id: 'sim_mount_1',
  name: 'Simulated Mount',
  deviceType: DeviceType.mount,
  driverType: DriverType.simulator,
  description: '',
  driverVersion: '',
);

UnifiedDiscoveryState _scanned(List<DeviceInfo> devices) =>
    UnifiedDiscoveryState(
      backendStates: {
        DriverType.simulator: BackendDiscoveryState(
          backend: DriverType.simulator,
          status: DiscoveryStatus.completed,
          devices: devices,
          completedAt: DateTime(2026, 11, 11, 21, 4),
        ),
      },
      rawDevices: devices,
    );

class _Discovery extends UnifiedDiscoveryNotifier {
  _Discovery(super.ref, UnifiedDiscoveryState seed) {
    state = seed;
  }

  Completer<void>? running;
  UnifiedDiscoveryState? next;

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {
    state = const UnifiedDiscoveryState(
      backendStates: {
        DriverType.simulator: BackendDiscoveryState(
          backend: DriverType.simulator,
          status: DiscoveryStatus.discovering,
        ),
      },
    );
    running = Completer<void>();
    await running!.future;
    state = next!;
  }
}

Future<(HarnessHandle, _Discovery)> _pump(
  WidgetTester tester,
  Widget child, {
  required UnifiedDiscoveryState scan,
  MockBackend? backend,
  List<Override> overrides = const [],
}) async {
  late _Discovery discovery;
  final handle = await pumpAppScreen(
    tester,
    child,
    size: const Size(420, 900),
    backend: backend,
    extraOverrides: [
      ...overrides,
      unifiedDiscoveryProvider.overrideWith(
        (ref) => discovery = _Discovery(ref, scan),
      ),
      profileConnectionStatusProvider.overrideWith(
        (ref, profile) => ProfileConnectionStatus(
          profileId: profile.id,
          connections: [
            for (final type in DeviceType.values)
              ProfileDeviceConnection(
                type: type,
                profileId: profile.deviceIdFor(type),
                connectedId: null,
                connectedState: DeviceConnectionState.disconnected,
              ),
          ],
        ),
      ),
    ],
  );
  return (handle, discovery);
}

void main() {
  testWidgets('says nothing before a scan has finished', (tester) async {
    await _pump(
      tester,
      const ProfileScanNotice(profile: _rig),
      scan: const UnifiedDiscoveryState(),
    );
    expect(find.byType(SkotiqBanner), findsNothing);
  });

  testWidgets('says nothing when the scan listed every profile device', (
    tester,
  ) async {
    await _pump(
      tester,
      const ProfileScanNotice(
        profile: EquipmentProfileModel(
          id: 2,
          name: 'Mount only',
          mountId: 'sim_mount_1',
        ),
      ),
      scan: _scanned([_mount()]),
    );
    expect(find.byType(SkotiqBanner), findsNothing);
  });

  testWidgets('names the device the scan missed', (tester) async {
    await _pump(
      tester,
      const ProfileScanNotice(profile: _rig),
      scan: _scanned([_mount()]),
    );
    expect(
      find.textContaining(
        "This profile's camera was not found in the last scan.",
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Simulated Camera was not listed at 21:04.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.text('Scan again'), findsOneWidget);
  });

  testWidgets('scan again rescans, stays up while scanning, then clears', (
    tester,
  ) async {
    final backend = mockBackend();
    when(backend.rescanDevices).thenAnswer((_) async {});
    final (_, discovery) = await _pump(
      tester,
      const ProfileScanNotice(profile: _rig),
      scan: _scanned([_mount()]),
      backend: backend,
    );

    await tester.tap(find.text('Scan again'));
    await tester.pump();
    await tester.pump();
    verify(backend.rescanDevices).called(1);
    expect(find.text('Scanning…'), findsOneWidget);
    expect(
      find.textContaining('Simulated Camera', findRichText: true),
      findsOneWidget,
      reason: 'the notice keeps what it said while the scan runs',
    );

    discovery.next = _scanned([
      _mount(),
      const DeviceInfo(
        id: 'sim_camera_1',
        name: 'Simulated Camera',
        deviceType: DeviceType.camera,
        driverType: DriverType.simulator,
        description: '',
        driverVersion: '',
      ),
    ]);
    discovery.running!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SkotiqBanner), findsNothing);
  });

  testWidgets('a failed scan says why', (tester) async {
    final backend = mockBackend();
    when(backend.rescanDevices).thenThrow(Exception('USB bus is busy'));
    await _pump(
      tester,
      const ProfileScanNotice(profile: _rig),
      scan: _scanned([_mount()]),
      backend: backend,
    );
    await tester.tap(find.text('Scan again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Scan failed'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
  });

  testWidgets('the Profiles list shows it above a Connect all that works', (
    tester,
  ) async {
    final connected = <EquipmentProfileModel>[];
    await _pump(
      tester,
      ProfileSidebar(
        selectedProfileId: 1,
        onProfileSelected: (_) {},
        onCreateProfile: () {},
        onEditProfile: (_) {},
        onConnectAll: connected.add,
        onDisconnectAll: () {},
        onSetDefault: (_) {},
        onActivateProfile: (_) {},
        onDuplicateProfile: (_) {},
        onDeleteProfile: (_) {},
        onReorderProfiles: (_, __) {},
      ),
      scan: _scanned([_mount()]),
      overrides: [
        sortedProfilesProvider.overrideWithValue(const [_rig]),
        activeEquipmentProfileProvider.overrideWithValue(_rig),
      ],
    );
    expect(find.byType(ProfileScanNotice), findsOneWidget);
    expect(
      find.textContaining('Simulated Camera was not listed', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.text('Connect all'));
    await tester.pump();
    expect(connected, [_rig]);
  });
}
