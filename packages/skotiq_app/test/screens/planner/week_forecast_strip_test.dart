// Widget tests for the "This Week" forecast strip (component C10).
//
// The strip is the entire fail-closed surface of the multi-night forecast, so
// these tests pin its branching directly rather than only through the planner
// shell (planner_screen_tabs_test.dart exercises it solely in the
// WeekForecast.unavailable state). We override weekForecastProvider with
// deterministic AsyncValues so no network is touched, and assert each rendered
// branch:
//
//   * provider error            -> SkotiqBanner + Retry action
//   * WeekForecast.unavailable  -> inline warning banner with the reason, NO
//                                  night cards
//   * available, empty nights   -> honest "nothing to forecast yet" empty state
//   * per-night forecastAvailable == false -> muted "No forecast" card
//   * per-night darkHours == 0  -> "No astronomical darkness" card
//   * available mixed week      -> one card per night, best night flagged with
//                                  the star marker
//   * score -> color mapping    -> the StatusDot color crosses the 0.33 / 0.66
//                                  thresholds (error / warning / success)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:skotiq_app/screens/planner/widgets/week_forecast_strip.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Build an available night with the given clear/total dark hours and an
/// optional up target so [NightForecast.score] is non-zero when desired.
NightForecast _night({
  required DateTime dateLocal,
  required double darkHours,
  required double clearDarkHours,
  bool withTarget = true,
  String targetName = 'M42',
}) {
  return NightForecast(
    nightDateLocal: dateLocal,
    astronomicalDuskUtc: DateTime.utc(2026, 5, 30, 4),
    astronomicalDawnUtc: DateTime.utc(2026, 5, 30, 11),
    darkHours: darkHours,
    clearDarkHours: clearDarkHours,
    meanCloudCoverDuringDark: 0.2,
    bestTargets: withTarget
        ? [
            ForecastTargetUp(
              targetId: 1,
              targetName: targetName,
              upDarkHours: clearDarkHours,
              maxAltitudeDeg: 60,
            ),
          ]
        : const [],
  );
}

/// Pump the strip with [week] as the resolved forecast (no network).
Widget _harness(WeekForecast week) {
  return ProviderScope(
    overrides: [
      inMemoryDatabaseOverride(),
      weekForecastProvider.overrideWith((ref) async => week),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 400,
          child: WeekForecastStrip(),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('provider error renders a SkotiqBanner with a Retry action',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          weekForecastProvider.overrideWith(
            (ref) => Future<WeekForecast>.error(
              StateError('forecast feed exploded'),
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1000,
              height: 400,
              child: WeekForecastStrip(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SkotiqBanner), findsOneWidget);
    // SkotiqBanner renders its title and message as one Text.rich, so the
    // title is a span rather than a whole Text widget.
    expect(find.textContaining('Forecast unavailable'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Retry'), findsOneWidget);
    // Fail-closed: no night cards rendered on an error.
    expect(find.byType(SkotiqPanel), findsNothing);
  });

  testWidgets(
      'WeekForecast.unavailable renders the inline warning banner and no cards',
      (tester) async {
    await tester.pumpWidget(_harness(
      const WeekForecast.unavailable(
        'Cloud forecast unavailable: network error',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(SkotiqBanner), findsOneWidget);
    expect(
      find.textContaining('Cloud forecast unavailable: network error'),
      findsOneWidget,
    );
    // No night cards in the unavailable state.
    expect(find.byType(SkotiqPanel), findsNothing);
    expect(find.text('This week'), findsNothing);
  });

  testWidgets('available but empty week renders the honest empty state',
      (tester) async {
    await tester.pumpWidget(_harness(
      const WeekForecast(nights: []),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('Nothing to forecast yet'), findsOneWidget);
  });

  testWidgets(
      'per-night forecastAvailable == false renders a "No forecast" card',
      (tester) async {
    final week = WeekForecast(nights: [
      NightForecast.unavailable(
        DateTime(2026, 5, 30, 12),
        'Cloud forecast does not reach this night',
      ),
    ]);
    await tester.pumpWidget(_harness(week));
    await tester.pumpAndSettle();

    expect(find.text('No forecast'), findsOneWidget);
    // The honest reason is surfaced, not swallowed.
    expect(
      find.textContaining('does not reach this night'),
      findsOneWidget,
    );
    // It still renders as a card in the strip.
    expect(find.byType(SkotiqPanel), findsOneWidget);
  });

  testWidgets('a night with darkHours == 0 renders "No astronomical darkness"',
      (tester) async {
    final week = WeekForecast(nights: [
      _night(
        dateLocal: DateTime(2026, 6, 21, 12),
        darkHours: 0,
        clearDarkHours: 0,
        withTarget: false,
      ),
    ]);
    await tester.pumpWidget(_harness(week));
    await tester.pumpAndSettle();

    expect(find.text('No astronomical darkness'), findsOneWidget);
    // No score bar / dark-hours row in this branch.
    expect(find.textContaining('clear'), findsNothing);
  });

  testWidgets(
      'available week renders one card per night with the best-night star',
      (tester) async {
    // Three nights: a poor (cloudy) night, a great (clear) night, a mid night.
    final week = WeekForecast(nights: [
      _night(
        dateLocal: DateTime(2026, 5, 30, 12),
        darkHours: 7,
        clearDarkHours: 1, // ~0.14 -> error/red
        targetName: 'Cloudy Night Target',
      ),
      _night(
        dateLocal: DateTime(2026, 5, 31, 12),
        darkHours: 7,
        clearDarkHours: 7, // 1.0 -> success/green, BEST
        targetName: 'Clear Night Target',
      ),
      _night(
        dateLocal: DateTime(2026, 6, 1, 12),
        darkHours: 7,
        clearDarkHours: 3.5, // 0.5 -> warning/amber
        targetName: 'Mid Night Target',
      ),
    ]);
    await tester.pumpWidget(_harness(week));
    await tester.pumpAndSettle();

    // One card per night.
    expect(find.byType(SkotiqPanel), findsNWidgets(3));
    // The section header is present in the available state.
    expect(find.text('This week'), findsOneWidget);
    // The clear-hours rows render for every dark night.
    expect(find.textContaining('clear'), findsNWidgets(3));
    // Each night surfaces its top target name.
    expect(find.text('Clear Night Target'), findsOneWidget);
    expect(find.text('Mid Night Target'), findsOneWidget);

    // Exactly one best-night star marker (the clear night).
    expect(find.byIcon(LucideIcons.star), findsOneWidget);
  });

  testWidgets('score color crosses the success / warning / error thresholds',
      (tester) async {
    // Build three nights whose scores land in each band and confirm the
    // StatusDot in each score bar carries the matching semantic color.
    final week = WeekForecast(nights: [
      _night(
        dateLocal: DateTime(2026, 5, 30, 12),
        darkHours: 10,
        clearDarkHours: 1, // 0.10 -> error
      ),
      _night(
        dateLocal: DateTime(2026, 5, 31, 12),
        darkHours: 10,
        clearDarkHours: 5, // 0.50 -> warning
      ),
      _night(
        dateLocal: DateTime(2026, 6, 1, 12),
        darkHours: 10,
        clearDarkHours: 8, // 0.80 -> success
      ),
    ]);

    late SkotiqColors colors;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          weekForecastProvider.overrideWith((ref) async => week),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(builder: (context) {
            colors = SkotiqColors.of(context);
            return const Scaffold(
              body: SizedBox(
                width: 1000,
                height: 400,
                child: WeekForecastStrip(),
              ),
            );
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dots = tester.widgetList<StatusDot>(find.byType(StatusDot)).toList();
    expect(dots, hasLength(3));
    final dotColors = dots.map((d) => d.color).toSet();
    // All three semantic colors must appear across the three score bars.
    expect(dotColors.contains(colors.error), isTrue);
    expect(dotColors.contains(colors.warning), isTrue);
    expect(dotColors.contains(colors.success), isTrue);
  });

  testWidgets(
      'no project target up: nothing is starred, not the earliest clouded night',
      (tester) async {
    // A fresh profile with no project targets — every night scores 0 because
    // NightForecast.score gates on bestTargets. The earliest night is also the
    // WORST weather (0 clear hours) while a later one is nearly all clear. The
    // strip must not recommend anything rather than star night one on the tie.
    final week = WeekForecast(nights: [
      _night(
        dateLocal: DateTime(2026, 5, 30, 12),
        darkHours: 6.2,
        clearDarkHours: 0, // fully clouded, and first in the list
        withTarget: false,
      ),
      _night(
        dateLocal: DateTime(2026, 5, 31, 12),
        darkHours: 6.4,
        clearDarkHours: 5.0, // the genuinely good night
        withTarget: false,
      ),
    ]);
    await tester.pumpWidget(_harness(week));
    await tester.pumpAndSettle();

    expect(find.byType(SkotiqPanel), findsNWidgets(2));
    expect(
      find.byIcon(LucideIcons.star),
      findsNothing,
      reason: 'no night is imageable, so none of them is the "best night"',
    );
    final cards =
        tester.widgetList<SkotiqPanel>(find.byType(SkotiqPanel)).toList();
    expect(
      cards.every((c) => c.selected == false),
      isTrue,
      reason: 'the selected-card accent must not mark a 0-score night either',
    );
  });
}
