import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/startup/quick_start_dialog.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

QuickStartContext _context({
  required bool canResume,
  bool stoppedByOperator = false,
  EquipmentSnapshot? snapshot,
}) {
  return QuickStartContext(
    sessionId: 7,
    sessionName: 'Andromeda night',
    targetName: 'M31',
    sequenceName: 'M31 sequence',
    completedFrames: 12,
    totalFrames: 20,
    lastSessionDate: DateTime.now().subtract(const Duration(hours: 2)),
    totalIntegrationHours: 1.2,
    canResumeFromCheckpoint: canResume,
    stoppedByOperator: stoppedByOperator,
    equipmentSnapshot: snapshot,
  );
}

Widget _host(QuickStartContext context) {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: QuickStartDialog(
        quickStartContext: context,
        onStartFresh: () {},
        onResumeProgress: () {},
        onSkip: () {},
      ),
    ),
  );
}

void main() {
  testWidgets('historical progress offers setup loading, not fake resume',
      (tester) async {
    await tester.pumpWidget(_host(_context(canResume: false)));
    await tester.pumpAndSettle();

    expect(find.text('Load Previous Setup'), findsOneWidget);
    expect(find.text('Restore progress'), findsNothing);
    expect(find.text('Start fresh'), findsNothing);
  });

  testWidgets('real backend checkpoint offers fresh and resume actions',
      (tester) async {
    await tester.pumpWidget(_host(_context(canResume: true)));
    await tester.pumpAndSettle();

    expect(find.text('Start fresh'), findsOneWidget);
    expect(find.text('Restore progress'), findsOneWidget);
    expect(find.text('Load Previous Setup'), findsNothing);
  });

  // The walk-through stopped a run by hand and was later offered to restore
  // it as if it had been lost, with "-10°C" and "Filter 1" for a run taken at
  // ambient through the L filter, and three buttons nobody explained.
  testWidgets('a stopped run says who stopped it and what it used',
      (tester) async {
    await tester.pumpWidget(_host(_context(
      canResume: true,
      stoppedByOperator: true,
      snapshot: EquipmentSnapshot(
        filterPosition: 0,
        filterName: 'L',
        cameraGain: 100,
        capturedAt: DateTime(2026, 11, 11),
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('You stopped it'), findsOneWidget);
    expect(find.text('L'), findsOneWidget);
    expect(find.text('Filter 1'), findsNothing);
    expect(find.textContaining('°C'), findsNothing);
    expect(find.textContaining('Skip changes nothing'), findsOneWidget);
  });
}
