import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/quick_start_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The Continue Session dialog must not describe a session it cannot describe.
///
/// Two live-found defects are pinned here:
///  * it dated yesterday's 14:57 session as "Today at 14:57", because
///    `Duration.inDays` truncates elapsed hours instead of comparing calendar
///    days; and
///  * it offered "Load Previous Setup" as an enabled primary action for a
///    session row carrying no profile id, no sequence id and no equipment
///    snapshot, so the button closed the dialog and reported success over a
///    no-op — while the two rows above it already read "Unknown Profile" and
///    "No Sequence".
QuickStartContext _context({
  DateTime? lastSessionDate,
  int? profileId,
  int? sequenceId,
  EquipmentSnapshot? snapshot,
  bool canResume = false,
}) {
  return QuickStartContext(
    sessionId: 7,
    sessionName: 'Andromeda night',
    targetName: 'M31',
    profileId: profileId,
    sequenceId: sequenceId,
    equipmentSnapshot: snapshot,
    completedFrames: 12,
    totalFrames: 20,
    lastSessionDate:
        lastSessionDate ?? DateTime.now().subtract(const Duration(hours: 2)),
    totalIntegrationHours: 1.2,
    canResumeFromCheckpoint: canResume,
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
  testWidgets('a session from the previous calendar day is not dated "Today"',
      (tester) async {
    // One second before midnight: always the previous calendar day, and always
    // less than 24 h ago, which is exactly the window `Duration.inDays` rounded
    // down to 0.
    final now = DateTime.now();
    final lastNight = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(seconds: 1));

    await tester.pumpWidget(_host(_context(lastSessionDate: lastNight)));
    await tester.pumpAndSettle();

    expect(find.text('Yesterday at 23:59'), findsOneWidget);
    expect(
      find.textContaining('Today at'),
      findsNothing,
      reason: 'A session that ended before midnight did not happen today.',
    );
  });

  testWidgets('an older session is dated explicitly, not relatively',
      (tester) async {
    final old = DateTime.now().subtract(const Duration(days: 30));

    await tester.pumpWidget(_host(_context(lastSessionDate: old)));
    await tester.pumpAndSettle();

    final expected = '${old.year}-${old.month.toString().padLeft(2, '0')}-'
        '${old.day.toString().padLeft(2, '0')}';
    expect(find.textContaining(expected), findsOneWidget);
  });

  testWidgets('a session with nothing recorded cannot be loaded',
      (tester) async {
    await tester.pumpWidget(_host(_context()));
    await tester.pumpAndSettle();

    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Load Previous Setup'),
    );
    expect(
      button.onPressed,
      isNull,
      reason: 'There is no profile, sequence or equipment snapshot to load, '
          'so the action must not be offered as if it would restore one.',
    );
    expect(find.textContaining('Nothing to load'), findsOneWidget);
  });

  testWidgets('a session that recorded a profile can still be loaded',
      (tester) async {
    await tester.pumpWidget(_host(_context(profileId: 3)));
    await tester.pumpAndSettle();

    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Load Previous Setup'),
    );
    expect(button.onPressed, isNotNull);
    expect(find.textContaining('Nothing to load'), findsNothing);
  });

  testWidgets('an equipment snapshot alone is enough to load', (tester) async {
    await tester.pumpWidget(
      _host(
        _context(
          snapshot: EquipmentSnapshot(
            cameraGain: 100,
            capturedAt: DateTime.now(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Load Previous Setup'),
    );
    expect(button.onPressed, isNotNull);
  });
}
