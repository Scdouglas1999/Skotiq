// The Connect-All result strip must read as a record, never as live state.
//
// Live finding: after Disconnect All the strip still showed four green
// "camera / mount / focuser / filter wheel Connected" chips under an undated
// "Connect All result" heading, while the main area said "No devices
// connected" and the profile card said 0/4. The strip deliberately outlives
// its sweep (that is how a failure is reviewed), so it has to date and score
// itself instead of borrowing the vocabulary of the live status surfaces.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/mock_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _profile = EquipmentProfile(
  id: '7',
  name: 'My First Rig',
  cameraId: 'sim_camera_1',
  mountId: 'sim_mount_1',
  isActive: true,
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
  testWidgets('a finished sweep is dated, scored and phrased in the past tense',
      (tester) async {
    final container = await _pumpEquipment(tester);
    final progress = container.read(deviceConnectionProgressProvider.notifier)
      ..startSweep()
      ..record(const DeviceConnectProgress(
        deviceType: 'camera',
        deviceId: 'sim_camera_1',
        status: DeviceConnectProgressStatus.connected,
      ))
      ..record(const DeviceConnectProgress(
        deviceType: 'mount',
        deviceId: 'sim_mount_1',
        status: DeviceConnectProgressStatus.failed,
        errorMessage: 'no response',
      ));
    progress.endSweep(at: DateTime(2026, 8, 3, 11, 16));
    await tester.pump();

    expect(find.text('Connect All at 11:16: 1 of 2 succeeded'), findsOneWidget);
    expect(
      find.text('Connected'),
      findsNothing,
      reason: 'a chip that outlives its sweep must not claim a live state — '
          'this one sat next to "No devices connected" after a Disconnect All',
    );
    expect(find.textContaining('Succeeded'), findsOneWidget);
    expect(find.textContaining('Failed'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('an in-flight sweep still reads as happening now',
      (tester) async {
    final container = await _pumpEquipment(tester);
    container.read(deviceConnectionProgressProvider.notifier)
      ..startSweep()
      ..record(const DeviceConnectProgress(
        deviceType: 'camera',
        deviceId: 'sim_camera_1',
        status: DeviceConnectProgressStatus.connecting,
      ));
    await tester.pump();

    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.textContaining('succeeded'), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
