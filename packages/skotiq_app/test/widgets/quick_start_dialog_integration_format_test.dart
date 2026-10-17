// The Continue Session dialog reported integration in whole minutes, so a
// short run read "4/4 frames captured, 0 minutes integration" while the
// dashboard's last-run card called the SAME run "12s". Telling an operator
// that the photons they just collected amount to zero is how you convince
// them the night did nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/quick_start_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

QuickStartContext _context({
  required double integrationHours,
  int completedFrames = 4,
  int totalFrames = 4,
}) {
  return QuickStartContext(
    sessionId: 7,
    sessionName: 'Andromeda night',
    targetName: 'M31',
    sequenceName: 'M31 sequence',
    completedFrames: completedFrames,
    totalFrames: totalFrames,
    lastSessionDate: DateTime.now().subtract(const Duration(hours: 2)),
    totalIntegrationHours: integrationHours,
    canResumeFromCheckpoint: true,
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
  testWidgets('a sub-minute session reports its real seconds, not 0 minutes',
      (tester) async {
    // 4 x 3s = 12s, the run from the report.
    await tester.pumpWidget(_host(_context(integrationHours: 12 / 3600)));
    await tester.pumpAndSettle();

    expect(find.text('4/4 frames captured, 12s integration'), findsOneWidget);
    expect(find.textContaining('0 minutes'), findsNothing);
  });

  testWidgets('90 seconds is not rounded up to 2 minutes', (tester) async {
    await tester.pumpWidget(_host(_context(integrationHours: 90 / 3600)));
    await tester.pumpAndSettle();

    expect(find.textContaining('1m 30s integration'), findsOneWidget);
  });

  testWidgets('a long session keeps hours, minutes and seconds',
      (tester) async {
    // 1.2h = 1h 12m 0s, the h/m/s shape the run cards and history tab use — not
    // "1.2 hours".
    await tester.pumpWidget(_host(_context(integrationHours: 1.2)));
    await tester.pumpAndSettle();

    expect(find.textContaining('1h 12m 0s integration'), findsOneWidget);
  });

  test('the shared formatter is what the run cards use', () {
    // ParsedRunStats.formatDuration is what the dashboard's last-run card and
    // the history tab render; both surfaces must describe one run
    // identically.
    final stats = ParsedRunStats.fromJson('{"integrationSecs": 12}');
    expect(stats.formatDuration(stats.integrationSecs),
        formatIntegrationHours(12 / 3600));
    expect(stats.formatDuration(stats.integrationSecs), '12s');
    expect(formatIntegrationSeconds(0), '0s');
    expect(formatIntegrationSeconds(-5), '0s');
    expect(formatIntegrationSeconds(59.6), '1m 0s');
  });
}
