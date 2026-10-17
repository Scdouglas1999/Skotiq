// The imaging Session card must not contradict itself.
//
// Reproduced defect: after "Incomplete Sessions Found > Resume" on a session
// with 8 successful exposures and 2400s integration, the card read
// "Captured  0 frames" directly above "Integration  40m 0s". Zero frames and
// forty minutes of integration cannot both be true. The count came from
// `recentSessionFramesProvider` — the frames captured in THIS app run, empty
// after a restart — while the integration line came from the restored
// `sessionState.totalIntegrationSecs`. The restored exposure count was in
// state the whole time and the card ignored it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/capture_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _SeededSessionState extends SessionStateNotifier {
  _SeededSessionState(super.ref, SessionState seed) {
    state = seed;
  }
}

Widget _app(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (context) => CapturePanel(colors: SkotiqColors.of(context)),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'a recovered session reports its restored frame count, not this run\'s '
      'empty list', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Exactly what SessionService.recoverSession restores from the DB row.
    final recovered = SessionState(
      isActive: true,
      dbSessionId: 3,
      startTime: DateTime.utc(2026, 7, 29, 20),
      completedExposures: 8,
      totalIntegrationSecs: 2400,
    );

    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      sessionStateProvider.overrideWith(
        (ref) => _SeededSessionState(ref, recovered),
      ),
    ]);
    addTearDown(container.dispose);

    // The in-run frame list is empty — the app was just restarted.
    expect(container.read(recentSessionFramesProvider), isEmpty);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('40m 0s'), findsOneWidget);
    expect(
      find.text('0'),
      findsNothing,
      reason: 'the card claimed zero frames beside 40 minutes of integration',
    );
    expect(find.text('8'), findsWidgets);
  });

  testWidgets('a single restored exposure is singular', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      sessionStateProvider.overrideWith(
        (ref) => _SeededSessionState(
          ref,
          SessionState(
            isActive: true,
            dbSessionId: 4,
            startTime: DateTime.utc(2026, 7, 29, 20),
            completedExposures: 1,
            totalIntegrationSecs: 300,
          ),
        ),
      ),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsWidgets);
  });
}
