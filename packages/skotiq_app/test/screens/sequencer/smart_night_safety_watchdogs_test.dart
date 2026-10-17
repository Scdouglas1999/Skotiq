import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_night_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show TargetVisibilityInfo;
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockLoggingService extends Mock implements LoggingService {}

/// Builds a [SmartNightPlannedTarget] with a single target whose meridian
/// transit can be positioned relative to its imaging window.
///
/// [transitOffset] is added to [windowStart] to place the transit; pass a
/// value strictly inside `(0, windowEnd - windowStart)` to put the transit
/// mid-window (which should trigger the meridian-flip watchdog), or outside
/// that range to keep it out of the window.
SmartNightPlannedTarget _plannedTarget({
  required DateTime windowStart,
  required DateTime windowEnd,
  Duration? transitOffset,
}) {
  final transit = transitOffset == null ? null : windowStart.add(transitOffset);
  final suggestion = TargetSuggestion.fromJson(<String, dynamic>{
    'targetId': 1,
    'targetName': 'NGC 7000',
    'raHours': 20.97,
    'decDegrees': 44.53,
    'totalScore': 82.0,
    'visibility': <String, dynamic>{
      'currentAltitude': 55.0,
      'currentAzimuth': 120.0,
      'airmass': 1.2,
      'moonDistance': 90.0,
      'transitAltitude': 80.0,
      if (transit != null) 'transitTime': transit.toIso8601String(),
      'isCircumpolar': false,
      'neverRises': false,
    },
  });
  return SmartNightPlannedTarget(
    suggestion: suggestion,
    windowStart: windowStart,
    windowEnd: windowEnd,
    filterPlans: const [
      SmartNightFilterPlan(filterName: 'L', count: 30, durationSecs: 120),
    ],
    integrationSecs: 3600,
    rationale: 'High score tonight',
  );
}

SmartNightPlan _plan({
  required List<SmartNightPlannedTarget> targets,
  double? rainOrCloudProbability,
}) {
  final start =
      targets.isEmpty ? DateTime(2026, 5, 29, 21) : targets.first.windowStart;
  final end =
      targets.isEmpty ? DateTime(2026, 5, 30, 5) : targets.last.windowEnd;
  return SmartNightPlan(
    sequence: Sequence.create(name: 'Smart Night test'),
    plannedTargets: targets,
    totalIntegrationSecs: 3600,
    estimatedWallClockSecs: 4200,
    warnings: const [],
    strategy: SmartNightStrategy.autoLrgb,
    settings: const SmartNightSettings(),
    context: SmartNightContext(
      windowStart: start,
      windowEnd: end,
      rainOrCloudProbability: rainOrCloudProbability,
    ),
  );
}

Future<void> _pumpSection(WidgetTester tester, SmartNightPlan plan) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SmartNightSafetyWatchdogsSection(
            plan: plan,
            colors: SkotiqColors.dark,
          ),
        ),
      ),
    ),
  );
}

void main() {
  final windowStart = DateTime(2026, 5, 29, 22);
  final windowEnd = DateTime(2026, 5, 30, 4);

  group('smartNightWatchdogsFor', () {
    test('emits the meridian-flip watchdog when a target transits mid-window',
        () {
      final plan = _plan(targets: [
        _plannedTarget(
          windowStart: windowStart,
          windowEnd: windowEnd,
          transitOffset: const Duration(hours: 3),
        ),
      ]);
      final watchdogs = smartNightWatchdogsFor(plan);
      expect(watchdogs.map((w) => w.title), contains('Meridian flip'));
    });

    test('omits the meridian-flip watchdog when transit is outside the window',
        () {
      final plan = _plan(targets: [
        // Transit after window end.
        _plannedTarget(
          windowStart: windowStart,
          windowEnd: windowEnd,
          transitOffset: const Duration(hours: 9),
        ),
      ]);
      final watchdogs = smartNightWatchdogsFor(plan);
      expect(watchdogs.map((w) => w.title), isNot(contains('Meridian flip')));
    });

    test('omits the meridian-flip watchdog when transit time is unknown', () {
      final plan = _plan(targets: [
        _plannedTarget(windowStart: windowStart, windowEnd: windowEnd),
      ]);
      final watchdogs = smartNightWatchdogsFor(plan);
      expect(watchdogs.map((w) => w.title), isNot(contains('Meridian flip')));
    });

    test('does not count transit exactly at the window boundary', () {
      final plan = _plan(targets: [
        // Transit == windowStart: service uses isAfter, so excluded.
        _plannedTarget(
          windowStart: windowStart,
          windowEnd: windowEnd,
          transitOffset: Duration.zero,
        ),
      ]);
      final watchdogs = smartNightWatchdogsFor(plan);
      expect(watchdogs.map((w) => w.title), isNot(contains('Meridian flip')));
    });

    test('emits the weather-recovery watchdog only above the 0.4 threshold',
        () {
      final above = _plan(
        targets: [
          _plannedTarget(windowStart: windowStart, windowEnd: windowEnd),
        ],
        rainOrCloudProbability: 0.6,
      );
      final below = _plan(
        targets: [
          _plannedTarget(windowStart: windowStart, windowEnd: windowEnd),
        ],
        rainOrCloudProbability: 0.3,
      );
      expect(
        smartNightWatchdogsFor(above).map((w) => w.title),
        contains('Weather recovery'),
      );
      expect(
        smartNightWatchdogsFor(below).map((w) => w.title),
        isNot(contains('Weather recovery')),
      );
    });
  });

  group('SmartNightSafetyWatchdogsSection', () {
    testWidgets('renders the section header and callout when a target transits',
        (tester) async {
      final plan = _plan(targets: [
        _plannedTarget(
          windowStart: windowStart,
          windowEnd: windowEnd,
          transitOffset: const Duration(hours: 3),
        ),
      ]);
      await _pumpSection(tester, plan);

      expect(find.text('Safety & Watchdogs'), findsOneWidget);
      expect(find.byIcon(LucideIcons.shieldAlert), findsOneWidget);

      // The callout copy must state the parallel / by-condition behaviour.
      // Locate the specific RichText whose spans describe the meridian flip
      // (the section also renders header/subtitle Text widgets).
      final calloutTexts = tester
          .widgetList<RichText>(
            find.descendant(
              of: find.byType(SmartNightSafetyWatchdogsSection),
              matching: find.byType(RichText),
            ),
          )
          .map((rt) => rt.text.toPlainText())
          .toList();
      final callout = calloutTexts.firstWhere(
        (t) => t.contains('Meridian flip'),
        orElse: () => '',
      );
      expect(callout, contains('Meridian flip'));
      expect(callout.toLowerCase(), contains('parallel'));
      expect(callout.toLowerCase(), contains('hour-angle'));
    });

    testWidgets('renders nothing when the plan installs no watchdogs',
        (tester) async {
      final plan = _plan(targets: [
        _plannedTarget(windowStart: windowStart, windowEnd: windowEnd),
      ]);
      await _pumpSection(tester, plan);

      expect(find.text('Safety & Watchdogs'), findsNothing);
      expect(find.byIcon(LucideIcons.shieldAlert), findsNothing);
    });
  });

  // Drift guard: the preview must agree with the sequence the builder
  // actually emits. Earlier the preview re-implemented the injection rules
  // by hand and the tests above checked the preview against itself — so a
  // change to the service's threshold/boundary could silently make the
  // preview lie. These tests run the REAL `SmartNightService.build()` and
  // assert the watchdog count from `smartNightWatchdogsFor` matches the
  // MeridianFlipNode / weather-unsafe RecoveryNode count in the emitted
  // tree.
  group('smartNightWatchdogsFor agrees with SmartNightService.build()', () {
    late SmartNightService service;
    late EquipmentProfileModel profile;

    setUp(() {
      service = SmartNightService(
        suggestionService: TargetSuggestionService(
          loggingService: _MockLoggingService(),
        ),
        logging: _MockLoggingService(),
      );
      profile = const EquipmentProfileModel(
        id: 1,
        name: 'ASI2600MM + RedCat 71',
        focalLength: 350,
        aperture: 71,
        focalRatio: 4.9,
        cameraName: 'ZWO ASI2600MM Pro',
        telescopeName: 'WO RedCat 71',
        mountName: 'ZWO AM5',
        defaultGain: 100,
        defaultOffset: 50,
        filterNames: ['L', 'R', 'G', 'B'],
      );
    });

    TargetSuggestion suggestion({required DateTime transitTime}) {
      return TargetSuggestion(
        targetId: 1,
        targetName: 'M51',
        raHours: 13.5,
        decDegrees: 47.2,
        totalScore: 85,
        objectType: 'galaxy',
        reasoning: 'High altitude, far from moon',
        visibility: TargetVisibilityInfo(
          currentAltitude: 55,
          currentAzimuth: 180,
          airmass: 1.3,
          peakAltitude: 80,
          riseTime: DateTime(2026, 5, 17, 22),
          setTime: DateTime(2026, 5, 18, 5),
          peakAltitudeTime: transitTime,
          moonDistance: 90,
          hoursAboveMinAlt: 6,
          transitTime: transitTime,
        ),
      );
    }

    SmartNightPlan buildPlan({
      required DateTime transitTime,
      double? rainOrCloudProbability,
    }) {
      return service.build(
        profile: profile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: SmartNightContext(
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          bortleClass: 4,
          rainOrCloudProbability: rainOrCloudProbability,
        ),
        selectedSuggestions: [suggestion(transitTime: transitTime)],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );
    }

    int emittedMeridianFlips(SmartNightPlan plan) =>
        plan.sequence.nodes.values.whereType<MeridianFlipNode>().length;

    int emittedWeatherRecoveries(SmartNightPlan plan) =>
        plan.sequence.nodes.values
            .whereType<RecoveryNode>()
            .where((r) => r.triggerType == TriggerType.weatherUnsafe)
            .length;

    test('meridian-flip preview matches emitted MeridianFlipNode (transits)',
        () {
      // Transit mid-window -> builder emits a flip, preview must claim it.
      final plan = buildPlan(transitTime: DateTime(2026, 5, 18, 1));
      expect(emittedMeridianFlips(plan), 1,
          reason: 'sanity: builder should emit a flip for mid-window transit');
      final hasMeridianWatchdog =
          smartNightWatchdogsFor(plan).any((w) => w.title == 'Meridian flip');
      expect(hasMeridianWatchdog, emittedMeridianFlips(plan) > 0);
    });

    test('meridian-flip preview matches emitted MeridianFlipNode (no transit)',
        () {
      // Transit after window end -> no flip emitted, no watchdog claimed.
      final plan = buildPlan(transitTime: DateTime(2026, 5, 18, 9));
      expect(emittedMeridianFlips(plan), 0,
          reason: 'sanity: builder should not emit a flip for out-of-window '
              'transit');
      final hasMeridianWatchdog =
          smartNightWatchdogsFor(plan).any((w) => w.title == 'Meridian flip');
      expect(hasMeridianWatchdog, emittedMeridianFlips(plan) > 0);
    });

    test('weather-recovery preview matches emitted RecoveryNode (above)', () {
      final plan = buildPlan(
        transitTime: DateTime(2026, 5, 18, 9),
        rainOrCloudProbability: 0.7,
      );
      expect(emittedWeatherRecoveries(plan), 1,
          reason: 'sanity: builder should emit a weather watchdog above 0.4');
      final hasWeatherWatchdog = smartNightWatchdogsFor(plan)
          .any((w) => w.title == 'Weather recovery');
      expect(hasWeatherWatchdog, emittedWeatherRecoveries(plan) > 0);
    });

    test('weather-recovery preview matches emitted RecoveryNode (below)', () {
      final plan = buildPlan(
        transitTime: DateTime(2026, 5, 18, 9),
        rainOrCloudProbability: 0.3,
      );
      expect(emittedWeatherRecoveries(plan), 0,
          reason: 'sanity: builder should not emit a weather watchdog '
              'below 0.4');
      final hasWeatherWatchdog = smartNightWatchdogsFor(plan)
          .any((w) => w.title == 'Weather recovery');
      expect(hasWeatherWatchdog, emittedWeatherRecoveries(plan) > 0);
    });
  });
}
