// Two chips in the shell status bar watched values that move far faster than
// anything they render, and the bar is on screen on every route.
//
// `localSiderealTimeProvider` is a `double` recomputed off a 1 Hz wall clock;
// the chip renders it as `HH:mm`. Watching the provider whole rebuilt the chip
// sixty times for every change an operator can see. The run pill had the same
// shape: while a sequence is running the executor republishes progress every
// second (`_startPerRunTimers`), and most of what moves in it — elapsed
// seconds, the smoothed ETA — is not on the pill.
//
// A rebuild that renders identical pixels is not free on this platform.
// Flutter's Linux GTK embedder ships with no damage-region support
// (`nm -D libflutter_linux_gtk.so | grep -c damage` → 0), so ANY dirty frame
// repaints the entire window. Measured on the profile bundle over the VM
// service, the LST chip alone was one full-window repaint per second, forever,
// on every screen.
//
// These tests pin the rule both chips now follow: watch what is DISPLAYED, so
// that a rebuild MEANS the rendered text moved. They drive the providers with
// zero-duration pumps, never `pump(Duration)`, so the bar's own one-second
// wall-clock tick can never fire inside the window being asserted on and
// confound the result.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/status_bar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../harness/pump_app_screen.dart';

/// The LST the overridden provider reports, so a test can advance sidereal time
/// without waiting on a wall clock.
final _lstSource = StateProvider<double?>((ref) => 12.5);

class _SitedSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      // A real site, so the chip is willing to show an LST at all: with the
      // 0/0 sentinel the bar correctly refuses to present the planetarium
      // default observer's sidereal time as the operator's.
      const AppSettingsState(latitude: 40.7, longitude: -74.0);
}

/// Runs [act], returning every widget name Flutter rebuilt while it ran.
///
/// The tracer is restored before returning rather than in a tear-down: the
/// binding asserts no foundation debug flag is still set when the test body
/// ends, and tear-downs run after that check.
Future<String> _rebuildsDuring(
  WidgetTester tester,
  Future<void> Function() act,
) async {
  final lines = <String>[];
  final previousPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) lines.add(message);
  };
  debugPrintRebuildDirtyWidgets = true;
  await act();
  debugPrintRebuildDirtyWidgets = false;
  debugPrint = previousPrint;
  return lines.join('\n');
}

void main() {
  testWidgets(
    'the LST chip rebuilds when its displayed minute rolls, and not before',
    (tester) async {
      final handle = await pumpAppScreen(
        tester,
        const Column(mainAxisSize: MainAxisSize.min, children: [StatusBar()]),
        size: const Size(2600, 900),
        extraOverrides: [
          appSettingsProvider.overrideWith(_SitedSettingsNotifier.new),
          localSiderealTimeProvider.overrideWith(
            (ref) => ref.watch(_lstSource),
          ),
        ],
        // The bar ticks a one-second clock; pumpAndSettle would never return.
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 50));

      final lst = handle.container.read(_lstSource.notifier);
      expect(
        find.descendant(
          of: find.byType(StatusBar),
          matching: find.text('12:30'),
        ),
        findsOneWidget,
        reason: 'the chip should be showing the seeded sidereal time',
      );

      // 12.505 h is 12:30.3 — sidereal time has moved, the rendered string has
      // not. This is the case that used to cost a full-window repaint.
      final withinMinute = await _rebuildsDuring(tester, () async {
        lst.state = 12.505;
        await tester.pump();
      });

      // 12.52 h is 12:31.2 — the minute rolls, so the chip MUST rebuild.
      // Deliberately not 12.5 + 1/60: that lands on 30.999... and would make
      // the test's own arithmetic, not the widget, decide the outcome.
      final minuteRoll = await _rebuildsDuring(tester, () async {
        lst.state = 12.52;
        await tester.pump();
      });

      // Assert the POSITIVE case first. An empty tracer log satisfies every
      // `isNot(contains(...))` below no matter what the app did, so the
      // instrument has to be shown working before an absence means anything.
      expect(
        minuteRoll,
        contains('_TimeDisplay'),
        reason: 'the chip did not rebuild when the displayed minute changed, '
            'so either the tracer is dead or the chip is now stale',
      );
      expect(
        find.descendant(
          of: find.byType(StatusBar),
          matching: find.text('12:31'),
        ),
        findsOneWidget,
        reason: 'the minute rolled but the chip still shows the old value',
      );

      expect(
        withinMinute,
        isNot(contains('_TimeDisplay')),
        reason: 'sidereal time advanced within the same displayed minute and '
            'the chip rebuilt anyway — on the Linux embedder that is a '
            'full-window repaint for a string that did not change',
      );

      expect(tester.takeException(), isNull);

      // Dispose so the clock timer is cancelled before the binding's timer
      // check runs.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'the run pill rebuilds when its displayed percent changes, and not before',
    (tester) async {
      final handle = await pumpAppScreen(
        tester,
        const Column(mainAxisSize: MainAxisSize.min, children: [StatusBar()]),
        size: const Size(2600, 900),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 50));

      final progress = handle.container.read(sequenceProgressProvider.notifier);
      progress.setTotals(10, 100);
      progress.updateProgress(completedExposures: 3);
      await tester.pump();

      // The elapsed seconds and the ETA are what the executor's one-second
      // timer moves, and neither is on this pill.
      final tickOnly = await _rebuildsDuring(tester, () async {
        progress.updateProgress(elapsedSecs: 42, estimatedRemainingSecs: 900);
        await tester.pump();
      });

      // A completed frame moves the percentage the pill prints.
      final frameLanded = await _rebuildsDuring(tester, () async {
        progress.updateProgress(completedExposures: 4);
        await tester.pump();
      });

      expect(
        frameLanded,
        contains('_SequenceIndicator'),
        reason: 'the run pill did not rebuild when its percentage changed, so '
            'either the tracer is dead or the pill is now stale',
      );
      expect(
        tickOnly,
        isNot(contains('_SequenceIndicator')),
        reason: 'the executor\'s one-second elapsed/ETA tick rebuilt the run '
            'pill, which shows neither — a full-window repaint per second for '
            'the length of a run',
      );

      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
