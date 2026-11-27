// Smart Night dialog widget smoke test.
//
// Pins the wizard's public surface:
//   * the dialog opens via SmartNightDialog() and shows the step
//     indicator with Window/Equipment/Targets/Strategy/Preview/Accept
//   * the close button dismisses the dialog
//   * the "Missing observer location" card appears when no location
//     is configured (the most common blocking gate)
//
// We intentionally keep this lean: the heavy logic lives in
// SmartNightService and is covered by 15 unit tests under
// skotiq_core/test/services/smart_night_service_test.dart. The
// widget test here just confirms the wizard can be opened, the steps
// render, and the validation gates fire.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_night_dialog.dart';
import 'package:skotiq_core/database.dart' show PolarAlignmentHistoryEntry;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_astro/skotiq_astro.dart' as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _TestSettingsNotifier extends AppSettingsNotifier {
  final Future<AppSettingsState> Function() _load;

  _TestSettingsNotifier(this._load);

  @override
  Future<AppSettingsState> build() => _load();
}

class _ShiftedClock implements Clock {
  const _ShiftedClock(this._at);
  final DateTime _at;

  @override
  DateTime now() => _at;

  @override
  DateTime nowUtc() => _at.toUtc();

  @override
  Duration get utcOffset => _at.timeZoneOffset;

  @override
  DateTime fromUtc(DateTime utc) => utc.toLocal();
}

const _ngc7380 = TargetSuggestion(
  targetId: 1,
  targetName: 'NGC7380',
  raHours: 22.78,
  decDegrees: 58.1,
  objectType: 'Emission Nebula',
  totalScore: 80,
  visibility: planetarium.TargetVisibilityInfo(
    currentAltitude: 60,
    currentAzimuth: 90,
    airmass: 1.2,
    moonDistance: 90,
    hoursAboveMinAlt: 6,
  ),
);

SensorSpecValue<T> _spec<T>(T value) => SensorSpecValue(
      value: value,
      origin: SensorSpecOrigin.userOverride,
      provenance: 'entered by the operator',
    );

final _knownSensor = ResolvedCameraSensorSpecs(
  reportedModel: 'Test camera',
  databaseEntry: null,
  pixelSizeMicrons: _spec(3.76),
  sensorWidthPx: _spec(6248),
  sensorHeightPx: _spec(4176),
  readNoiseE: _spec(1.5),
  fullWellE: _spec(51000.0),
  qePeakFraction: _spec(0.8),
);

/// Records the context the preview is built from, then stops the build.
class _RecordingSmartNightService extends SmartNightService {
  _RecordingSmartNightService(Ref ref, {required this.onBuild})
      : super(
          suggestionService: ref.watch(targetSuggestionServiceProvider),
          logging: ref.watch(loggingServiceProvider),
          floor: ref.watch(altitudeFloorProvider),
        );

  final void Function(SmartNightContext context) onBuild;

  @override
  SmartNightPlan build({
    required EquipmentProfileModel profile,
    required List<String> availableFilters,
    required double latitudeDeg,
    required double longitudeDeg,
    required SmartNightContext context,
    required List<TargetSuggestion> selectedSuggestions,
    required SmartNightStrategy? strategy,
    required SmartNightSettings settings,
    required PlanTimer planTimer,
    SmartNightExposureContext? exposureContext,
    SmartNightFlatPlan? flatPlan,
    Map<int, List<IntegrationGoalProgress>> integrationGoals = const {},
    Map<int, FilterSet> targetSets = const {},
  }) {
    onBuild(context);
    throw StateError('preview stopped by the test');
  }
}

Future<ProviderContainer> _pumpDialog(
  WidgetTester tester, {
  List<Override> overrides = const [],
  SmartNightDialog dialog = const SmartNightDialog(),
  Future<AppSettingsState> Function()? settingsLoader,
  Future<void> Function(ProviderContainer container)? before,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1024, 800);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      appSettingsProvider.overrideWith(
        () => _TestSettingsNotifier(
          settingsLoader ?? () async => const AppSettingsState(),
        ),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  if (before != null) await tester.runAsync(() => before(container));

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Center(child: dialog),
        ),
      ),
    ),
  );
  // Resolve the one provider the dialog now treats as launch-authoritative.
  // Errors are intentionally swallowed here so failure-state tests can assert
  // on the rendered retry surface.
  try {
    await container.read(appSettingsProvider.future);
  } catch (_) {}
  await tester.pump();
  return container;
}

void main() {
  testWidgets('settings failure blocks the wizard instead of using defaults',
      (tester) async {
    await _pumpDialog(
      tester,
      settingsLoader: () async =>
          throw StateError('settings database unavailable'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cannot load Smart Night settings'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
  });

  testWidgets('SmartNightDialog renders header + step indicator',
      (tester) async {
    await _pumpDialog(tester);
    expect(find.text('Smart Night'), findsOneWidget);
    // The six step labels are visible in the indicator strip.
    expect(find.text('1. Window'), findsOneWidget);
    expect(find.text('2. Equipment'), findsOneWidget);
    expect(find.text('3. Targets'), findsOneWidget);
    expect(find.text('4. Strategy'), findsOneWidget);
    expect(find.text('5. Preview'), findsOneWidget);
    expect(find.text('6. Accept'), findsOneWidget);
  });

  testWidgets(
      'SmartNightDialog shows "Missing observer location" '
      'when no lat/lon configured', (tester) async {
    await _pumpDialog(tester);
    // Default AppSettings has lat=lon=0.0 → appObserverLocationProvider
    // returns null → wizard surfaces the missing-location warning card
    // on step 1.
    expect(
      find.textContaining('No observer location set'),
      findsOneWidget,
    );
  });

  for (final (horizon, label) in [
    (null, '30\u00B0 minimum'),
    ('{"E":40}', 'Your horizon'),
  ]) {
    testWidgets('the window step names the altitude floor in force: $label', (
      tester,
    ) async {
      await _pumpDialog(
        tester,
        settingsLoader: () async =>
            const AppSettingsState(latitude: 40, longitude: -75),
        overrides: [
          if (horizon != null)
            horizonProfileProvider.overrideWithValue(
              SiteHorizonProfile.fromJson(horizon),
            ),
        ],
      );
      await tester.pump();
      expect(
        find.byKey(const Key('smartNight.altitudeFloorInForce')),
        findsOneWidget,
      );
      expect(find.text(label), findsOneWidget);
      // Smart Night has no minimum altitude of its own to edit.
      expect(find.text('Min altitude'), findsNothing);
    });
  }

  testWidgets('SmartNightDialog blocks a fabricated midnight-sun window',
      (tester) async {
    // The dialog plans for the real tonight, so pick the pole that is in
    // polar day now: the north between the equinoxes, the south otherwise.
    final now = DateTime.now();
    final northernSummer = now.isAfter(DateTime(now.year, 3, 21)) &&
        now.isBefore(DateTime(now.year, 9, 23));
    await _pumpDialog(
      tester,
      overrides: [
        inMemoryDatabaseOverride(),
        appObserverLocationProvider.overrideWithValue(
          LocationSettings(latitude: northernSummer ? 89 : -89, longitude: 0),
        ),
      ],
    );

    expect(find.textContaining('Sun does not set'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text('Tonight\'s dark window'), findsOneWidget);
    expect(find.textContaining('Sun does not set'), findsWidgets);
  });

  testWidgets(
      'SmartNightDialog footer has Next and no redundant Cancel '
      '(dismissal is the header close button)', (tester) async {
    await _pumpDialog(tester);
    expect(find.text('Next'), findsOneWidget);
    // The header ✕ is the single dismissal affordance (covered by the
    // close-button dismissal test above).
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets(
      'seeded dialog opens in hand-pick mode and shows the source banner '
      '(C11 handoff)', (tester) async {
    await _pumpDialog(
      tester,
      dialog: const SmartNightDialog(
        seedTargetIds: [50],
        seedSourceLabel: 'Galaxy Season',
      ),
      overrides: [
        inMemoryDatabaseOverride(),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            name: 'Test rig',
            focalLength: 600,
            aperture: 120,
            filterNames: ['L', 'R', 'G', 'B'],
          ),
        ),
        // The seeded target (50) plus another, both up tonight, so the seed has
        // no "below cut-off" gap and the banner is the plain info variant.
        tonightSuggestionsProvider.overrideWith((ref) async => const [
              TargetSuggestion(
                targetId: 50,
                targetName: 'M51',
                raHours: 13.5,
                decDegrees: 47.2,
                totalScore: 90,
                visibility: planetarium.TargetVisibilityInfo(
                  currentAltitude: 60,
                  currentAzimuth: 180,
                  transitAltitude: 70,
                  airmass: 1.2,
                  moonDistance: 90,
                  hoursAboveMinAlt: 5,
                ),
              ),
              TargetSuggestion(
                targetId: 99,
                targetName: 'M101',
                raHours: 14.05,
                decDegrees: 54.3,
                totalScore: 80,
                visibility: planetarium.TargetVisibilityInfo(
                  currentAltitude: 55,
                  currentAzimuth: 175,
                  transitAltitude: 65,
                  airmass: 1.3,
                  moonDistance: 95,
                  hoursAboveMinAlt: 4,
                ),
              ),
            ]),
      ],
    );
    await tester.pumpAndSettle();

    // Step 1 (Window) -> Next -> Step 2 (Equipment) -> Next -> Step 3 (Targets).
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // We're on the Targets step in hand-pick mode (not auto-pick).
    expect(find.text('3. Targets'), findsOneWidget);
    expect(find.text('Hand-pick from suggestions below'), findsOneWidget);
    // The seed banner names the source campaign.
    expect(
      find.textContaining('Pre-selected the incomplete targets from '
          '"Galaxy Season"'),
      findsOneWidget,
    );
  });

  testWidgets('the wizard cools to the profile set-point, as Plan tonight does',
      (tester) async {
    await _pumpDialog(
      tester,
      overrides: [
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            name: 'Cooled rig',
            focalLength: 600,
            aperture: 120,
            defaultCoolingTemp: -5,
            filterNames: ['L'],
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    final coolTo = find.descendant(
      of: find.ancestor(
        of: find.text('Cool to'),
        matching: find.byType(Row),
      ),
      matching: find.byType(SmartNightNumberField),
    );
    expect(tester.widget<SmartNightNumberField>(coolTo.first).initial, -5);
  });

  group('the "Has flat panel" switch', () {
    Future<void> openEquipment(
        WidgetTester tester, String? calibratorId) async {
      await _pumpDialog(
        tester,
        overrides: [
          appObserverLocationProvider.overrideWithValue(
            const LocationSettings(latitude: 40, longitude: -75),
          ),
          activeEquipmentProfileProvider.overrideWithValue(
            EquipmentProfileModel(
              name: 'Panel rig',
              focalLength: 600,
              aperture: 120,
              filterNames: const ['L'],
              coverCalibratorId: calibratorId,
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }

    SkotiqSwitch panelSwitch(WidgetTester tester) => tester.widget(
          find.descendant(
            of: find.ancestor(
              of: find.text('Has flat panel'),
              matching: find.byType(Row),
            ),
            matching: find.byType(SkotiqSwitch),
          ),
        );

    // The plan takes panel flats with a bound calibrator whatever the switch
    // says, so the switch says so and cannot be turned off.
    testWidgets('is on and fixed with a calibrator bound', (tester) async {
      await openEquipment(tester, 'cover-1');
      final toggle = panelSwitch(tester);
      expect(toggle.value, isTrue);
      expect(toggle.onChanged, isNull);
      expect(find.textContaining('Toggle this on'), findsNothing);
    });

    testWidgets('a blank calibrator id is no calibrator', (tester) async {
      await openEquipment(tester, '  ');
      final toggle = panelSwitch(tester);
      expect(toggle.value, isFalse);
      expect(toggle.onChanged, isNotNull);
      expect(find.textContaining('cover calibrator is bound'), findsNothing);
    });

    testWidgets('is the operator\'s to set with none bound', (tester) async {
      await openEquipment(tester, null);
      final toggle = panelSwitch(tester);
      expect(toggle.value, isFalse);
      expect(toggle.onChanged, isNotNull);
    });
  });

  // The days since the last polar alignment are counted on the app's clock,
  // as the rest of the plan is.
  testWidgets('the polar alignment age is read at the app clock',
      (tester) async {
    final wallNow = DateTime.now();
    final appNow = wallNow.add(const Duration(days: 40));
    SmartNightContext? planned;
    await _pumpDialog(
      tester,
      before: (container) async {
        container.listen(lastPolarAlignmentProvider(7), (_, __) {});
        await container.read(lastPolarAlignmentProvider(7).future);
      },
      overrides: [
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Test rig',
            focalLength: 600,
            aperture: 120,
            filterNames: ['L'],
          ),
        ),
        clockProvider.overrideWithValue(_ShiftedClock(appNow)),
        lastPolarAlignmentProvider(7).overrideWith(
          (ref) async => PolarAlignmentHistoryEntry(
            id: 1,
            equipmentProfileId: 7,
            initialAzimuthError: 0,
            initialAltitudeError: 0,
            initialTotalError: 0,
            finalAzimuthError: 0,
            finalAltitudeError: 0,
            finalTotalError: 0,
            startedAt: wallNow.subtract(const Duration(days: 1, hours: 1)),
            completedAt: wallNow.subtract(const Duration(days: 1)),
            autoCompleted: true,
            isNorth: true,
            configJson: '{}',
          ),
        ),
        tonightSuggestionsProvider.overrideWith((_) async => const [_ngc7380]),
        activeCameraSensorSpecsProvider
            .overrideWith((ref) async => _knownSensor),
        smartNightServiceProvider.overrideWith(
          (ref) => _RecordingSmartNightService(
            ref,
            onBuild: (context) => planned = context,
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();
    for (var step = 0; step < 4 && planned == null; step++) {
      await tester.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    expect(planned, isNotNull, reason: 'the preview was built');
    expect(planned!.daysSinceLastPolarAlignment, 41);
  });

  testWidgets('SmartNightDialog blocks equipment step when aperture is missing',
      (tester) async {
    await _pumpDialog(
      tester,
      overrides: [
        inMemoryDatabaseOverride(),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            name: 'No aperture rig',
            focalLength: 600,
            aperture: 0,
            filterNames: ['L'],
          ),
        ),
      ],
    );

    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2. Equipment'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.textContaining('Equipment profile is missing aperture'),
      findsOneWidget,
    );
    expect(find.text('2. Equipment'), findsOneWidget);
    expect(find.text('3. Targets'), findsOneWidget);
  });

  testWidgets('saved hand-pick preference seeds the Targets step',
      (tester) async {
    await _pumpDialog(
      tester,
      settingsLoader: () async =>
          const AppSettingsState(smartNightAutoSelect: false),
      overrides: [
        inMemoryDatabaseOverride(),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            name: 'Test rig',
            focalLength: 600,
            aperture: 120,
            filterNames: ['L'],
          ),
        ),
        tonightSuggestionsProvider.overrideWith((_) async => const []),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Hand-pick from suggestions below'), findsOneWidget);
  });

  testWidgets('suggestion failure is retryable and cannot advance',
      (tester) async {
    await _pumpDialog(
      tester,
      overrides: [
        inMemoryDatabaseOverride(),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            name: 'Test rig',
            focalLength: 600,
            aperture: 120,
            filterNames: ['L'],
          ),
        ),
        tonightSuggestionsProvider.overrideWith(
          (_) async => throw StateError('catalog unavailable'),
        ),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to load suggestions'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('Could not load target suggestions'),
        findsOneWidget);
    expect(find.text('Hand-pick from suggestions below'), findsNothing);
    expect(find.text('3. Targets'), findsOneWidget);
  });

  group('a plan saved earlier tonight', () {
    const profile = EquipmentProfileModel(
      id: 3,
      name: 'Test rig',
      focalLength: 600,
      aperture: 120,
      filterNames: ['L', 'R', 'G', 'B'],
    );
    const lat = 40.0;
    const lon = -75.0;

    List<Override> draftOverrides() => [
          inMemoryDatabaseOverride(),
          appObserverLocationProvider.overrideWithValue(
            const LocationSettings(latitude: lat, longitude: lon),
          ),
          activeEquipmentProfileProvider.overrideWithValue(profile),
          // A fixed floor: these tests read the planning service before the
          // dialog is up, and the floor's own inputs load from the database.
          altitudeFloorProvider.overrideWithValue(
            const AltitudeFloor(horizon: null, minimumDeg: 30),
          ),
        ];

    /// Files a draft under tonight's night, as the dialog keys it.
    Future<SmartNightDraft> saveDraft(ProviderContainer container) {
      final night = container
          .read(smartNightServiceProvider)
          .calculateWindow(latitudeDeg: lat, longitudeDeg: lon)
          .start;
      return container.read(smartNightDraftServiceProvider).savePending(
            profileId: '${profile.id}',
            astronomicalDay: night,
            plan: _draftPlan(),
          );
    }

    testWidgets('is offered and continues on the Preview step', (tester) async {
      await _pumpDialog(
        tester,
        overrides: draftOverrides(),
        before: saveDraft,
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('You have a plan saved from'), findsOneWidget);
      expect(find.textContaining('M51 · '), findsOneWidget);

      await tester.tap(find.textContaining('Continue the draft from'));
      await tester.pumpAndSettle();

      expect(find.text('Tonight: 1 target, 1.0h integration'), findsOneWidget);
      expect(find.textContaining('You have a plan saved from'), findsNothing);
    });

    testWidgets('Start over deletes it and leaves the new plan to build',
        (tester) async {
      late SmartNightDraft draft;
      final container = await _pumpDialog(
        tester,
        overrides: draftOverrides(),
        before: (c) async => draft = await saveDraft(c),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start over'));
      await tester.pumpAndSettle();

      expect(find.textContaining('You have a plan saved from'), findsNothing);
      expect(find.text('Tonight\'s dark window'), findsOneWidget);
      final left = await tester.runAsync(
        () => container.read(smartNightDraftServiceProvider).loadById(draft.id),
      );
      expect(left, isNull);
    });

    testWidgets('reads its saved time and target windows on the site clock',
        (tester) async {
      // Seven hours off the device's own zone, so the two clocks cannot agree.
      final at = DateTime.now();
      final site = FixedOffsetClock(
        utcOffset: at.timeZoneOffset + const Duration(hours: 7),
        label: 'Site',
      );
      String hm(DateTime t) => site.hm(t);
      late SmartNightDraft draft;
      await _pumpDialog(
        tester,
        overrides: [
          ...draftOverrides(),
          clockProvider.overrideWithValue(site),
        ],
        before: (c) async {
          final night = c
              .read(smartNightServiceProvider)
              .calculateWindow(latitudeDeg: lat, longitudeDeg: lon)
              .start;
          draft = await c.read(smartNightDraftServiceProvider).savePending(
                profileId: '${profile.id}',
                astronomicalDay: night,
                plan: _draftPlan(at),
              );
        },
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You have a plan saved from ${hm(draft.updatedAt)}'),
        findsOneWidget,
      );
      await tester.tap(find.textContaining('Continue the draft from'));
      await tester.pumpAndSettle();

      final end = at.add(const Duration(hours: 3));
      expect(find.text('${hm(at)} → ${hm(end)} (3.0h)'), findsOneWidget);
    });

    testWidgets('is not offered when there is none', (tester) async {
      await _pumpDialog(tester, overrides: draftOverrides());
      await tester.pumpAndSettle();
      expect(find.textContaining('You have a plan saved from'), findsNothing);
      expect(find.text('Tonight\'s dark window'), findsOneWidget);
    });
  });

  group('the window step reads on the site clock', () {
    // Seven hours off the device's own zone, so the two clocks cannot agree.
    final device = DateTime.now();
    final site = FixedOffsetClock(
      utcOffset: device.timeZoneOffset + const Duration(hours: 7),
      label: 'Site',
    );
    final start = DateTime.utc(
      device.year,
      device.month,
      device.day,
      device.hour,
      device.minute,
    ).add(const Duration(hours: 2)).toLocal();
    final end = start.add(const Duration(hours: 6));

    Future<void> pumpWindow(WidgetTester tester) async {
      await _pumpDialog(
        tester,
        settingsLoader: () async =>
            const AppSettingsState(latitude: 40, longitude: -75),
        overrides: [
          clockProvider.overrideWithValue(site),
          smartNightServiceProvider.overrideWith(
            (ref) => _FixedWindowSmartNightService(ref, start, end),
          ),
        ],
      );
      await tester.pump();
    }

    testWidgets('labels', (tester) async {
      await pumpWindow(tester);
      expect(
        find.text('Start: ${site.dateHm(start)}'),
        findsOneWidget,
      );
      expect(
        find.text('End: ${site.dateHm(end)}'),
        findsOneWidget,
      );
    });

    testWidgets('the picker starts at the site time and keeps the instant',
        (tester) async {
      await pumpWindow(tester);
      final wall = site.wallClockOf(start);
      await tester.tap(find.text('Change').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DatePickerDialog>(find.byType(DatePickerDialog))
            .initialDate,
        DateTime(wall.year, wall.month, wall.day),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TimePickerDialog>(find.byType(TimePickerDialog))
            .initialTime,
        TimeOfDay(hour: wall.hour, minute: wall.minute),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(
        find.text('Start: ${ClockFormat.dateHm(wall)}'),
        findsOneWidget,
        reason: 'confirming the shown date and time keeps the same instant',
      );
    });
  });
}

SmartNightPlan _draftPlan([DateTime? at]) {
  final root = InstructionSetNode(id: 'root', name: 'Root', childIds: const []);
  final now = at ?? DateTime.now();
  return SmartNightPlan(
    sequence: Sequence(
      id: 'seq-draft',
      name: 'Smart Night M51',
      nodes: {'root': root},
      rootNodeId: 'root',
      createdAt: now,
      modifiedAt: now,
    ),
    plannedTargets: [
      SmartNightPlannedTarget(
        suggestion: const TargetSuggestion(
          targetId: 1,
          targetName: 'M51',
          raHours: 13.5,
          decDegrees: 47.2,
          totalScore: 90,
          visibility: planetarium.TargetVisibilityInfo(
            currentAltitude: 60,
            currentAzimuth: 180,
            airmass: 1.2,
            moonDistance: 90,
          ),
        ),
        windowStart: now,
        windowEnd: now.add(const Duration(hours: 3)),
        filterPlans: const [
          SmartNightFilterPlan(filterName: 'L', count: 60, durationSecs: 60),
        ],
        integrationSecs: 3600,
        rationale: 'High altitude',
        filterReason: 'LRGB: M51 is a galaxy.',
      ),
    ],
    totalIntegrationSecs: 3600,
    estimatedWallClockSecs: 4000,
    warnings: const [],
    strategy: SmartNightStrategy.autoLrgb,
    settings: const SmartNightSettings(),
    context: SmartNightContext(
      windowStart: now,
      windowEnd: now.add(const Duration(hours: 3)),
    ),
  );
}

/// A dark window fixed by the test, so the labels have known instants.
class _FixedWindowSmartNightService extends SmartNightService {
  _FixedWindowSmartNightService(Ref ref, this._start, this._end)
      : super(
          suggestionService: ref.watch(targetSuggestionServiceProvider),
          logging: ref.watch(loggingServiceProvider),
          floor: ref.watch(altitudeFloorProvider),
        );

  final DateTime _start;
  final DateTime _end;

  @override
  ({
    DateTime start,
    DateTime end,
    planetarium.TwilightTimes twilight
  }) calculateWindow({
    required double latitudeDeg,
    required double longitudeDeg,
    DateTime? now,
  }) =>
      (start: _start, end: _end, twilight: const planetarium.TwilightTimes());

  @override
  ({
    DateTime start,
    DateTime end,
    planetarium.TwilightTimes twilight
  }) calculateRemainingWindow({
    required double latitudeDeg,
    required double longitudeDeg,
    DateTime? now,
  }) =>
      (start: _start, end: _end, twilight: const planetarium.TwilightTimes());
}
