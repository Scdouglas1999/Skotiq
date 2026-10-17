// DEVICE HEARTBEATS must never invent a "last seen" it does not have.
//
// Only the camera tracks a successful-communication timestamp, so seconds after
// connecting six simulated devices every other device carries
// `lastSuccessfulTimestampMs: 0`. Rendering epoch zero as an age gives
// "OK - 20676d ago" (56.6 years) next to a green OK dot, with the overall score
// still reading 100 - Excellent: the one widget whose job is to catch a device
// that has gone quiet, untrustworthy on the happy path.
//
// No timestamp is UNKNOWN, and it must read as unknown.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/equipment_health_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

const _report = EquipmentHealthReport(
  score: 100,
  insights: [
    EquipmentHealthInsight(
      title: 'Equipment health stable',
      message: 'No negative trend exceeded alert thresholds.',
      severity: EquipmentHealthSeverity.info,
    ),
  ],
);

Future<void> _pumpPanel(
  WidgetTester tester,
  List<DeviceHealthSnapshot> snapshots,
) async {
  await pumpAppScreen(
    tester,
    const EquipmentHealthPanel(),
    size: const Size(900, 700),
    settle: false,
    extraOverrides: [
      equipmentHealthExpandedProvider.overrideWith((ref) => true),
      deviceHealthSnapshotsProvider.overrideWithValue(snapshots),
      equipmentHealthReportProvider.overrideWithValue(
        const AsyncValue.data(_report),
      ),
    ],
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
      'a device with no successful-communication timestamp reads '
      'unknown, not an epoch-zero age', (tester) async {
    await _pumpPanel(tester, const [
      DeviceHealthSnapshot(
        deviceId: 'sim:mount:1',
        deviceLabel: 'Simulated Mount',
        lastSuccessfulTimestampMs: 0,
        isHealthy: true,
      ),
    ]);

    expect(find.text('Simulated Mount'), findsOneWidget);
    expect(
      find.textContaining('ago'),
      findsNothing,
      reason: 'an age computed from epoch zero is 56 years of fiction',
    );
    expect(find.text('OK - last contact unknown'), findsOneWidget);
  });

  testWidgets('an unhealthy device with no timestamp says so without an age',
      (tester) async {
    await _pumpPanel(tester, const [
      DeviceHealthSnapshot(
        deviceId: 'native:builtin_guider:multi_star',
        deviceLabel: 'Built-in Multi-Star Guider',
        lastSuccessfulTimestampMs: 0,
        isHealthy: false,
      ),
    ]);

    expect(find.text('Unhealthy - last contact unknown'), findsOneWidget);
    expect(find.textContaining('ago'), findsNothing);
  });

  testWidgets('a real timestamp still renders its age', (tester) async {
    final tenSecondsAgo = DateTime.now().subtract(const Duration(seconds: 10));
    await _pumpPanel(tester, [
      DeviceHealthSnapshot(
        deviceId: 'sim:camera:1',
        deviceLabel: 'Simulated Camera',
        lastSuccessfulTimestampMs: tenSecondsAgo.millisecondsSinceEpoch,
        isHealthy: true,
      ),
    ]);

    expect(find.textContaining('OK - 1'), findsOneWidget);
    expect(find.textContaining('s ago'), findsOneWidget);
  });
}
