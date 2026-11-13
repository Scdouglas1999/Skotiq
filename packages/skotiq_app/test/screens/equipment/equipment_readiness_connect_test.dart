// The Equipment screen's Readiness rows point at the Equipment screen itself
// for disconnected devices, so "Connect devices" there has to connect the
// profile's devices rather than navigate to where the user already is.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/equipment_readiness_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../harness/harness.dart';

const _profile = EquipmentProfileModel(
  id: 1,
  name: 'My First Rig',
  cameraId: 'sim_camera_1',
  mountId: 'sim_mount_1',
);

class _RecordingDeviceService extends DeviceService {
  _RecordingDeviceService(super.ref, super.backend);

  final List<int?> sweeps = <int?>[];

  @override
  Stream<DeviceConnectProgress> connectAllFromProfile(
    EquipmentProfileModel profile,
  ) {
    sweeps.add(profile.id);
    return const Stream<DeviceConnectProgress>.empty();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Connect devices connects the active profile', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: EquipmentReadinessPanel()),
      size: const Size(500, 900),
      settle: false,
      extraOverrides: <Override>[
        readinessReportProvider.overrideWithValue(
          buildReadinessReport(
            cameraConnected: false,
            mountConnected: false,
            hasProfile: true,
            locationSet: true,
            outputPathSet: true,
            plateSolverReady: true,
            darkLibraryHasCoverage: true,
            focusKnown: true,
            offlineProfileDevices: const <String>[],
            hasActiveProfile: true,
            assignedProfileDeviceCount: 2,
            otherAssignedProfileDeviceCount: 0,
          ),
        ),
        activeEquipmentProfileProvider.overrideWithValue(_profile),
        deviceServiceProvider.overrideWith((ref) {
          final service =
              _RecordingDeviceService(ref, ref.watch(backendProvider));
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Connect devices'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final service =
        handle.container.read(deviceServiceProvider) as _RecordingDeviceService;
    expect(service.sweeps, <int?>[1]);
  });
}
