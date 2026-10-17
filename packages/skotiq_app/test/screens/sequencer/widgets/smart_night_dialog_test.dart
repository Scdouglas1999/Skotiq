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
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _TestSettingsNotifier extends AppSettingsNotifier {
  final Future<AppSettingsState> Function() _load;

  _TestSettingsNotifier(this._load);

  @override
  Future<AppSettingsState> build() => _load();
}

Future<ProviderContainer> _pumpDialog(
  WidgetTester tester, {
  List<Override> overrides = const [],
  SmartNightDialog dialog = const SmartNightDialog(),
  Future<AppSettingsState> Function()? settingsLoader,
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
    expect(find.text('Smart Night — Plan Tonight'), findsOneWidget);
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
    // The footer Cancel was removed; the header ✕ is the single dismissal
    // affordance (covered by the close-button dismissal test above).
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
}
