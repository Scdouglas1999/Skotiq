// "Connect all" must connect the PROFILE, and the same profile every time.
//
// Live finding: the first press connected the profile's four devices; an
// identical press five minutes later — after the Discovery panel had re-scanned
// — connected those four PLUS a simulated safety monitor that is not in the
// profile. The header then read "5 connected · 1 unsaved" while the profile
// card and the status bar both still read 4/4, and the extra device vanished on
// the next launch. The button sat under the profile card, so its scope has to
// be the profile, not whatever discovery happened to cache.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// A profile with one camera and NO safety monitor.
const _profile = EquipmentProfile(
  id: '7',
  name: 'My First Rig',
  cameraId: 'sim_camera_1',
  cameraName: 'Simulated Camera',
  isActive: true,
);

/// A safety monitor the discovery cache has surfaced but nobody assigned.
const _looseSafetyMonitor = UnifiedDevice(
  canonicalName: 'simulated safety monitor',
  displayName: 'Simulated Safety Monitor',
  type: DeviceType.safetyMonitor,
  availableBackends: {
    DriverType.simulator: DeviceInfo(
      id: 'sim_safety_monitor_1',
      name: 'Simulated Safety Monitor',
      deviceType: DeviceType.safetyMonitor,
      driverType: DriverType.simulator,
      description: '',
      driverVersion: '1.0',
    ),
  },
);

Future<ProviderContainer> _pumpEquipment(WidgetTester tester) async {
  final database = mockDatabase();
  addTearDown(database.close);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1600, 1200);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final backend = _MockNetworkBackend();
  when(() => backend.eventStream)
      .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  when(() => backend.getActiveProfile()).thenAnswer((_) async => _profile);
  when(() => backend.getProfiles()).thenAnswer((_) async => const [_profile]);

  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider
            .overrideWith((ref) => _StubBackendNotifier(ref, backend)),
        databaseProvider.overrideWithValue(database),
        selectedEquipmentProfileIdProvider.overrideWith((ref) => 7),
        activeProfileProvider.overrideWith((ref) => Stream.value(null)),
        allProfilesProvider.overrideWith((ref) => Stream.value(const [])),
        // Discovery has run and cached an unassigned safety monitor — the
        // exact state that made the second press behave differently.
        unifiedSafetyMonitorsProvider.overrideWithValue([_looseSafetyMonitor]),
      ],
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return const MaterialApp(home: Scaffold(body: EquipmentScreen()));
      }),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

void main() {
  testWidgets('Connect All touches no device outside the profile',
      (tester) async {
    final container = await _pumpEquipment(tester);

    await tester
        .tap(find.widgetWithText(SkotiqButton, 'Connect devices').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final progress = container.read(deviceConnectionProgressProvider);
    expect(
      progress.byDeviceType.keys,
      isNot(contains('safety monitor')),
      reason: 'the profile lists no safety monitor, so the sweep must not '
          'connect the one discovery happened to cache',
    );
    expect(
      progress.byDeviceType.keys,
      contains('camera'),
      reason: 'the profile\'s own devices must still be swept',
    );
    expect(find.text('safety monitor'), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
