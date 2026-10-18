import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/imaging/widgets/meridian_flip_countdown_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Builds a [MeridianCountdownState] with sensible defaults so each test only
/// has to vary the field under examination.
MeridianCountdownState _state({
  required bool isArmed,
  Duration? timeToFlip,
  bool isSequencerOwned = false,
  String? disabledReason,
  MeridianTriggerMethod method = MeridianTriggerMethod.minutesPastMeridian,
  double hourAngleHours = 0.0,
  String? sideOfPier,
}) {
  return MeridianCountdownState(
    isArmed: isArmed,
    timeToFlip: timeToFlip,
    isAutomaticWatchdog: true,
    isSequencerOwned: isSequencerOwned,
    disabledReason: disabledReason,
    method: method,
    hourAngleHours: hourAngleHours,
    sideOfPier: sideOfPier,
  );
}

Future<void> _pump(
  WidgetTester tester,
  MeridianCountdownState state, {
  int? dismissedSeverityIndex,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 600);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The projection is now a pure synchronous Provider; override it with a
        // fixed state. (The banner owns its own 15s ticker, cancelled on dispose,
        // so no timer leaks past this test's teardown.)
        meridianCountdownProvider.overrideWith((ref) => state),
        if (dismissedSeverityIndex != null)
          meridianBannerDismissedSeverityProvider
              .overrideWith((ref) => dismissedSeverityIndex),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: Center(child: MeridianFlipCountdownBanner()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  group('formatTimeToFlip', () {
    test('rounds up to whole minutes so it never under-reports', () {
      // 2m05s of real time must read as 3m, not 2m.
      expect(formatTimeToFlip(const Duration(minutes: 2, seconds: 5)), '3m');
      expect(formatTimeToFlip(const Duration(minutes: 2)), '2m');
    });

    test('formats hours and minutes', () {
      expect(
        formatTimeToFlip(const Duration(hours: 1, minutes: 30)),
        '1h 30m',
      );
    });

    test('drops the minute component on a whole hour', () {
      expect(formatTimeToFlip(const Duration(hours: 2)), '2h');
    });

    test('round-up means any positive duration reads at least 1m, never 0m',
        () {
      expect(formatTimeToFlip(const Duration(seconds: 20)), '1m');
      expect(formatTimeToFlip(const Duration(seconds: 1)), '1m');
    });

    test('zero or negative reads as "now"', () {
      expect(formatTimeToFlip(Duration.zero), 'now');
      expect(formatTimeToFlip(const Duration(seconds: -30)), 'now');
    });
  });

  group('MeridianFlipCountdownBanner render rules', () {
    testWidgets('not armed renders nothing (non-intrusive)', (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: false,
          disabledReason: 'Mount not connected',
        ),
      );

      expect(find.byType(MeridianFlipCountdownBanner), findsOneWidget);
      // Collapses to zero size; surfaces no disabled-reason chatter.
      expect(
          tester.getSize(find.byType(MeridianFlipCountdownBanner)), Size.zero);
      expect(find.textContaining('Meridian flip'), findsNothing);
    });

    testWidgets('armed numeric countdown shows tabular time + automatic copy',
        (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 7),
        ),
      );

      expect(find.textContaining('Meridian flip in'), findsOneWidget);
      expect(find.text('7m'), findsOneWidget);
      expect(
        find.text(
          'Automatic — the meridian-flip watchdog will run this for you. '
          'No action needed.',
        ),
        findsOneWidget,
      );
      // The flip icon is the design-reference flip glyph.
      expect(find.byIcon(LucideIcons.flipHorizontal2), findsOneWidget);
    });

    testWidgets('countdown under 10 minutes escalates to the warning tone',
        (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 6),
        ),
      );

      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(MeridianFlipCountdownBanner),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration as BoxDecoration;
      const colors = SkotiqColors.dark;
      // Border carries the warning accent (alpha 0.35), not info.
      expect(
          decoration.border!.top.color, colors.warning.withValues(alpha: 0.35));
    });

    testWidgets(
        'a calm countdown above the warning threshold leaves the banner to '
        'the toolbar chip', (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 30),
        ),
      );

      expect(
        tester.getSize(find.byType(MeridianFlipCountdownBanner)),
        Size.zero,
        reason: 'an informational countdown must not push the view down',
      );
      expect(find.textContaining('Meridian flip'), findsNothing);
    });

    testWidgets('sequencer-owned countdown uses the sequence copy',
        (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 8),
          isSequencerOwned: true,
        ),
      );

      expect(
        find.text('Handled automatically by the running sequence.'),
        findsOneWidget,
      );
      expect(find.textContaining('watchdog will run this'), findsNothing);
    });

    testWidgets(
        'tracking-limit method (null countdown) is calm status, not a banner',
        (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: true,
          timeToFlip: null,
          isSequencerOwned: true,
          method: MeridianTriggerMethod.minutesBeforeLimit,
          disabledReason: 'Monitored by sequencer (tracking-limit method)',
        ),
      );

      expect(
        tester.getSize(find.byType(MeridianFlipCountdownBanner)),
        Size.zero,
      );
      expect(find.textContaining('Meridian flip'), findsNothing);
    });

    testWidgets('flip imminent (zero) shows warning imminent banner',
        (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: true,
          timeToFlip: Duration.zero,
        ),
      );

      expect(find.text('Meridian flip imminent'), findsOneWidget);
      expect(find.textContaining('No action needed'), findsOneWidget);

      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(MeridianFlipCountdownBanner),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration as BoxDecoration;
      const colors = SkotiqColors.dark;
      expect(
          decoration.border!.top.color, colors.warning.withValues(alpha: 0.35));
    });

    testWidgets('pier-side renders as a trailing chip when present',
        (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 5),
          sideOfPier: 'west',
        ),
      );

      expect(find.text('Pier West'), findsOneWidget);
    });

    testWidgets('no pier chip when the mount does not report a side',
        (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 5),
        ),
      );

      expect(find.textContaining('Pier'), findsNothing);
    });

    testWidgets('is dismissable but offers no manual flip-action button',
        (tester) async {
      await _pump(
        tester,
        _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 5),
        ),
      );

      // It must never present an action that triggers/cancels the flip (that
      // would contradict the "automatic watchdog" promise)...
      expect(find.byType(SkotiqButton), findsNothing);
      // ...but it IS dismissable: a quiet close affordance silences the status.
      expect(find.byTooltip('Dismiss'), findsOneWidget);
      expect(find.byIcon(LucideIcons.x), findsOneWidget);
    });

    testWidgets('tapping dismiss hides the banner', (tester) async {
      await _pump(
        tester,
        _state(isArmed: true, timeToFlip: const Duration(minutes: 5)),
      );
      expect(find.textContaining('Meridian flip in'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();

      expect(find.textContaining('Meridian flip in'), findsNothing);
      expect(
        tester.getSize(find.byType(MeridianFlipCountdownBanner)),
        Size.zero,
      );
    });

    testWidgets('stays hidden at or below the dismissed severity',
        (tester) async {
      // Dismissed at the warning tone; a flip still at that tone stays
      // silenced.
      await _pump(
        tester,
        _state(isArmed: true, timeToFlip: const Duration(minutes: 4)),
        dismissedSeverityIndex: SkotiqAlertSeverity.warning.index,
      );

      expect(
        tester.getSize(find.byType(MeridianFlipCountdownBanner)),
        Size.zero,
      );
    });

    testWidgets('re-surfaces when the flip escalates past the dismissed tone',
        (tester) async {
      // Dismissed at info, but the flip is now within the warning threshold —
      // the more-urgent banner must come back despite the earlier dismissal.
      await _pump(
        tester,
        _state(isArmed: true, timeToFlip: const Duration(minutes: 6)),
        dismissedSeverityIndex: SkotiqAlertSeverity.info.index,
      );

      expect(find.textContaining('Meridian flip in'), findsOneWidget);
    });
  });

  // Dismissal-reset rules: a mount heartbeat flap disarms the countdown for
  // tens of seconds; the dismissal must survive that, but still reset for a
  // genuinely new cycle (disarmed past the grace, or the pier side changed —
  // the flip this countdown was for has happened).
  group('dismissal reset grace', () {
    /// Pump the banner with a test-owned driver behind the countdown provider
    /// so each test can disarm / re-arm mid-flight.
    Future<ProviderContainer> pumpDriven(
      WidgetTester tester,
      StateProvider<MeridianCountdownState> driver,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(900, 600);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meridianCountdownProvider.overrideWith((ref) => ref.watch(driver)),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: Center(child: MeridianFlipCountdownBanner()),
            ),
          ),
        ),
      );
      await tester.pump();
      return ProviderScope.containerOf(
        tester.element(find.byType(MeridianFlipCountdownBanner)),
      );
    }

    StateProvider<MeridianCountdownState> armedDriver({String? sideOfPier}) =>
        StateProvider<MeridianCountdownState>(
          (ref) => _state(
            isArmed: true,
            timeToFlip: const Duration(minutes: 5),
            sideOfPier: sideOfPier,
          ),
        );

    testWidgets('a brief disarm does not un-dismiss the banner',
        (tester) async {
      final driver = armedDriver(sideOfPier: 'east');
      final container = await pumpDriven(tester, driver);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.textContaining('Meridian flip in'), findsNothing);

      // Heartbeat flap: disarmed for 30 s (well under the 5-minute grace).
      container.read(driver.notifier).state = _state(isArmed: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));

      container.read(driver.notifier).state = _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 5),
          sideOfPier: 'east');
      await tester.pump();

      expect(find.textContaining('Meridian flip in'), findsNothing);
    });

    testWidgets('a disarm past the grace resets the dismissal', (tester) async {
      final driver = armedDriver();
      final container = await pumpDriven(tester, driver);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.textContaining('Meridian flip in'), findsNothing);

      container.read(driver.notifier).state = _state(isArmed: false);
      await tester.pump();
      await tester.pump(
        MeridianFlipCountdownBanner.kDismissalResetGrace +
            const Duration(minutes: 1),
      );

      container.read(driver.notifier).state =
          _state(isArmed: true, timeToFlip: const Duration(minutes: 5));
      await tester.pump();

      expect(find.textContaining('Meridian flip in'), findsOneWidget);
    });

    testWidgets('a pier-side change resets the dismissal immediately',
        (tester) async {
      final driver = armedDriver(sideOfPier: 'east');
      final container = await pumpDriven(tester, driver);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.textContaining('Meridian flip in'), findsNothing);

      // The flip actually happened: the mount reports the other pier side.
      container.read(driver.notifier).state = _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 5),
          sideOfPier: 'west');
      await tester.pump();

      expect(find.textContaining('Meridian flip in'), findsOneWidget);
    });

    testWidgets(
        'a pier-side change across a disarm gap still resets the dismissal',
        (tester) async {
      final driver = armedDriver(sideOfPier: 'east');
      final container = await pumpDriven(tester, driver);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.textContaining('Meridian flip in'), findsNothing);

      // The flap blanks the pier side (mount state resets on disconnect);
      // the mount comes back on the other side — the flip happened in the
      // gap. Comparing prev→next alone would see null→west and miss it.
      container.read(driver.notifier).state = _state(isArmed: false);
      await tester.pump();
      container.read(driver.notifier).state = _state(
          isArmed: true,
          timeToFlip: const Duration(minutes: 5),
          sideOfPier: 'west');
      await tester.pump();

      expect(find.textContaining('Meridian flip in'), findsOneWidget);
    });
  });

  // The calm countdown moved out of the banner into a compact chip in the
  // viewer toolbar. The two must never show the same flip at once.
  group('MeridianFlipChip', () {
    Future<void> pumpBoth(
      WidgetTester tester,
      MeridianCountdownState state,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(900, 600);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meridianCountdownProvider.overrideWith((ref) => state)],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: Column(
                children: <Widget>[
                  MeridianFlipChip(),
                  MeridianFlipCountdownBanner(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a far-off countdown is a chip, with the explanation behind it',
        (tester) async {
      await pumpBoth(
        tester,
        _state(
          isArmed: true,
          timeToFlip: const Duration(hours: 3, minutes: 6),
          sideOfPier: 'east',
        ),
      );

      expect(find.text('Flip in 3h 6m'), findsOneWidget);
      final tooltip = tester.widget<SkotiqTooltip>(
        find.ancestor(
          of: find.text('Flip in 3h 6m'),
          matching: find.byType(SkotiqTooltip),
        ),
      );
      expect(tooltip.message, contains('watchdog will run this for you'));
      expect(tooltip.message, contains('Pier East'));
      expect(
        tester.getSize(find.byType(MeridianFlipCountdownBanner)),
        Size.zero,
        reason: 'the chip says it; the banner must not say it again',
      );
    });

    testWidgets('a flip that needs attention is the banner, not the chip',
        (tester) async {
      await pumpBoth(
        tester,
        _state(isArmed: true, timeToFlip: const Duration(minutes: 6)),
      );

      expect(find.textContaining('Flip in'), findsNothing);
      expect(find.textContaining('Meridian flip in'), findsOneWidget);
    });

    testWidgets('an imminent flip is the banner, not the chip', (tester) async {
      await pumpBoth(
        tester,
        _state(isArmed: true, timeToFlip: Duration.zero),
      );

      expect(find.textContaining('Flip in'), findsNothing);
      expect(find.text('Meridian flip imminent'), findsOneWidget);
    });

    testWidgets('a tracking-limit flip reads "Flip armed" with no countdown',
        (tester) async {
      await pumpBoth(
        tester,
        _state(
          isArmed: true,
          timeToFlip: null,
          isSequencerOwned: true,
          method: MeridianTriggerMethod.minutesBeforeLimit,
          disabledReason: 'Monitored by sequencer (tracking-limit method)',
        ),
      );

      expect(find.text('Flip armed'), findsOneWidget);
      expect(find.textContaining('Flip in'), findsNothing);
      final tooltip = tester.widget<SkotiqTooltip>(
        find.ancestor(
          of: find.text('Flip armed'),
          matching: find.byType(SkotiqTooltip),
        ),
      );
      expect(tooltip.message, contains('Monitored by the sequencer'));
    });

    testWidgets('no flip armed shows neither', (tester) async {
      await pumpBoth(
        tester,
        _state(isArmed: false, disabledReason: 'Mount not connected'),
      );

      expect(find.byType(SkotiqChip), findsNothing);
      expect(
        tester.getSize(find.byType(MeridianFlipCountdownBanner)),
        Size.zero,
      );
    });
  });
}
