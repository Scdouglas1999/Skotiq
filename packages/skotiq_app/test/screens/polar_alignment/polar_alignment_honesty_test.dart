import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_app/widgets/tutorial_keys/polar_alignment_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// A finished polar-alignment run used to wear a green tick and a green "+0%"
/// no matter what residual it ended on, and the idle All-Sky reticle claimed
/// "Within acceptance" before a single frame had been captured.
class _FixedAlignmentNotifier extends PolarAlignmentStateNotifier {
  _FixedAlignmentNotifier(super.ref, PolarAlignmentState fixed) {
    // ignore: invalid_use_of_protected_member
    state = fixed;
  }
}

class _SiteSettings extends AppSettingsNotifier {
  _SiteSettings(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  @override
  Future<AppSettingsState> build() async =>
      AppSettingsState(latitude: latitude, longitude: longitude);
}

const _config = PolarAlignmentConfig(autoCompleteThreshold: 30.0);

PolarAlignmentState _completed({
  required double initialTotal,
  required double finalTotal,
}) =>
    PolarAlignmentState(
      phase: PolarAlignPhase.complete,
      config: _config,
      startedAt: DateTime(2026, 8, 2, 10),
      initialError: _error(initialTotal),
      currentError: _error(finalTotal),
    );

PolarAlignmentError _error(double total) => PolarAlignmentError(
      azimuthError: total,
      altitudeError: 0,
      totalError: total,
      currentRa: 0,
      currentDec: 89,
      targetRa: 0,
      targetDec: 90,
      timestamp: DateTime(2026, 8, 2, 10, 30),
    );

GoRouter _router() => GoRouter(
      initialLocation: '/polar-alignment',
      routes: [
        GoRoute(
          path: '/polar-alignment',
          builder: (_, __) => const PolarAlignmentScreen(),
        ),
      ],
    );

Future<HarnessHandle> _pumpScreen(
  WidgetTester tester, {
  PolarAlignmentState? alignmentState,
  double latitude = 40,
  double longitude = -75,
}) async {
  final handle = await pumpAppScreen(
    tester,
    MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: _router(),
    ),
    size: const Size(1400, 900),
    settle: false,
    extraOverrides: [
      appSettingsProvider
          .overrideWith(() => _SiteSettings(latitude, longitude)),
      if (alignmentState != null)
        polarAlignmentStateProvider.overrideWith(
          (ref) => _FixedAlignmentNotifier(ref, alignmentState),
        ),
    ],
  );
  await tester.pump(const Duration(milliseconds: 200));
  return handle;
}

SkotiqButton _startButton(WidgetTester tester) =>
    tester.widget<SkotiqButton>(
      find.byKey(PolarAlignmentTutorialKeys.startBtn),
    );

Tooltip _startTooltip(WidgetTester tester) => tester.widget<Tooltip>(
      find
          .ancestor(
            of: find.byKey(PolarAlignmentTutorialKeys.startBtn),
            matching: find.byType(Tooltip),
          )
          .first,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a run that ends far above threshold is not called Complete',
      (tester) async {
    await _pumpScreen(
      tester,
      alignmentState: _completed(initialTotal: 1800, finalTotal: 1800),
    );

    expect(find.text('Alignment complete'), findsNothing);
    expect(find.text('Alignment stopped'), findsOneWidget);
    expect(find.text('+0%'), findsNothing);
    expect(find.text('No change'), findsOneWidget);
  });

  testWidgets('a run that got worse says so', (tester) async {
    await _pumpScreen(
      tester,
      alignmentState: _completed(initialTotal: 1800, finalTotal: 1900),
    );

    expect(find.text('Alignment stopped'), findsOneWidget);
    expect(find.text('Worse'), findsOneWidget);
  });

  testWidgets('a run inside the threshold still reads Complete',
      (tester) async {
    await _pumpScreen(
      tester,
      alignmentState: _completed(initialTotal: 1800, finalTotal: 12),
    );

    expect(find.text('Alignment complete'), findsOneWidget);
    expect(find.text('+99%'), findsOneWidget);
  });

  testWidgets('idle All-Sky reticle does not claim acceptance', (tester) async {
    await _pumpScreen(tester);
    await tester.tap(find.text('All-sky'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Within acceptance — hold steady'), findsNothing);
    expect(find.text('Not measured'), findsOneWidget);
    // formatPolarError renders sub-arcminute values as `0.0"`.
    expect(find.text('0.0"'), findsNothing);
  });

  testWidgets('no observing location is disclosed on the idle screen',
      (tester) async {
    await _pumpScreen(tester, latitude: 0, longitude: 0);

    // Two surfaces by design: the panel discloses the missing site, and the
    // footer beside the refusing Start button names it as a blocker. A hover
    // tooltip is not an explanation the operator who clicks can read.
    expect(
      find.textContaining('No observing location set'),
      findsWidgets,
    );
  });

  testWidgets('a configured site drops the location warning', (tester) async {
    await _pumpScreen(tester);

    expect(find.textContaining('No observing location set'), findsNothing);
  });

  testWidgets('Start Alignment is blocked while no site is set',
      (tester) async {
    // The banner is a disclosure; this is the actual refusal. The site is a
    // prerequisite in the same sense as the camera and the solver, so it must
    // disable Start with a reason rather than only failing on the way in.
    await _pumpScreen(tester, latitude: 0, longitude: 0);

    expect(
        _startTooltip(tester).message, contains('No observing location set'));
    expect(_startButton(tester).onPressed, isNull);
  });

  testWidgets('a configured site is not what blocks Start', (tester) async {
    await _pumpScreen(tester);

    // Still disabled — no camera or mount in this fixture — but the site is no
    // longer among the reasons, which proves the new gate is not always on.
    final message = _startTooltip(tester).message;
    expect(message, contains('Camera and mount not connected'));
    expect(message, isNot(contains('observing location')));
  });

  testWidgets('a stopped run is listed as Stopped, not as an improvement',
      (tester) async {
    final handle = await _pumpScreen(tester);

    // A cancelled all-sky run: the "initial" error is whichever noisy sample
    // landed first, so the naive percentage reads +97% for an axis nobody
    // touched.
    await handle.database.polarAlignmentHistoryDao.insertResult(
      PolarAlignmentResult(
        initialError: _error(40104),
        finalError: _error(1376),
        startedAt: DateTime(2026, 8, 2, 10, 39),
        completedAt: DateTime(2026, 8, 2, 10, 41),
        config: _config,
        autoCompleted: false,
      ),
    );
    await handle.container
        .read(polarAlignmentUiStateProvider.notifier)
        .toggleHistoryPanel();
    // The history panel reads a drift watch-stream; give it frames to emit.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // 1376" in the unit an operator adjusts in (see formatPolarError).
    expect(find.text('Final: 22\' 56"'), findsOneWidget);
    expect(find.text('+97%'), findsNothing);
    expect(find.text('Stopped'), findsOneWidget);
  });

  testWidgets('a run that reached the target keeps its improvement badge',
      (tester) async {
    final handle = await _pumpScreen(tester);

    await handle.database.polarAlignmentHistoryDao.insertResult(
      PolarAlignmentResult(
        initialError: _error(1800),
        finalError: _error(12),
        startedAt: DateTime(2026, 8, 2, 10, 39),
        completedAt: DateTime(2026, 8, 2, 10, 41),
        config: _config,
        autoCompleted: true,
      ),
    );
    await handle.container
        .read(polarAlignmentUiStateProvider.notifier)
        .toggleHistoryPanel();
    // The history panel reads a drift watch-stream; give it frames to emit.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(find.text('+99%'), findsOneWidget);
    expect(find.text('Stopped'), findsNothing);
  });
}
