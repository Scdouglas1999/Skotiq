// The Tonight list is a grid: every row and the header above it share one set
// of column widths, so a column's name sits over its values and the values do
// not move from row to row. The selected row's wider "Image tonight" button
// used to push that row's readouts left of everyone else's, and the header was
// laid out on its own, some 100px off its columns.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/provider_teardown.dart';
import '../scheduler/scheduler_test_doubles.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

class _MockLogger extends Mock implements LoggingService {}

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40.0, longitude: -75.0);
}

TargetSuggestion _s(int id, String name, String type, double size, double mag,
    String con, int h, int m, double alt, double hours) {
  final now = DateTime.now();
  final t = DateTime(now.year, now.month, now.day, h, m);
  return TargetSuggestion(
    targetId: id,
    targetName: name,
    raHours: 1.5,
    decDegrees: 30,
    totalScore: 96,
    visibility: TargetVisibilityInfo(
      currentAltitude: 47.5,
      currentAzimuth: 120,
      airmass: 1.1,
      moonDistance: 104,
      transitAltitude: alt,
      transitTime: t,
      riseTime: now.subtract(const Duration(hours: 4)),
      setTime: now.add(const Duration(hours: 8)),
      hoursAboveMinAlt: hours,
    ),
    objectType: type,
    sizeArcmin: size,
    magnitude: mag,
    constellation: con,
  );
}

Future<void> _pumpTonight(
  WidgetTester tester, {
  TargetPlatform? platform,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final dao = _MockSettingsDao();
  when(dao.getAllSettings).thenAnswer((_) async => <String, String>{});
  when(() => dao.getSetting(any())).thenAnswer((_) async => null);
  when(() => dao.setSetting(any(), any())).thenAnswer((_) async {});
  final list = [
    _s(1, 'NGC0579', 'Galaxy', 1.1, 13.3, 'Tri', 0, 46, 84, 10),
    _s(2, 'NGC0582', 'Galaxy', 2.1, 13.2, 'Tri', 0, 46, 84, 10),
    _s(3, 'M33', 'Galaxy', 62.1, 5.8, 'Tri', 0, 48, 81, 9.75),
    _s(4, 'NGC0575', 'Galaxy', 1.4, 13.0, 'Psc', 0, 45, 71, 9.25),
  ];
  await tester.pumpWidget(ProviderScope(
    overrides: [
      inMemoryDatabaseOverride(),
      tonightSuggestionsProvider.overrideWith((ref) async => list),
      smartNightExposureContextProvider.overrideWith((ref) async => null),
      appSettingsProvider.overrideWith(() => _StubAppSettingsNotifier()),
      settingsDaoProvider.overrideWithValue(dao),
      loggingServiceProvider.overrideWithValue(_MockLogger()),
      activeTransientAlertsProvider
          .overrideWith((ref) => Stream.value(const <TransientAlert>[])),
      allTargetProgressProvider
          .overrideWith((ref) async => <int, TargetProgress>{}),
      schedulerEngineProvider.overrideWithValue(buildTestSchedulerEngine()),
      schedulerStatusProvider.overrideWith((ref) => FakeSchedulerStatusNotifier(
          const SchedulerStatus(state: SchedulerState.idle))),
      currentSchedulerDecisionProvider
          .overrideWith((ref) => FakeCurrentSchedulerDecisionNotifier(null)),
      allIntegrationGoalsProvider
          .overrideWith((ref) async => <IntegrationGoal>[]),
      integrationGoalProgressProvider
          .overrideWith((ref, _) async => <IntegrationGoalProgress>[]),
      projectListProvider
          .overrideWith((ref) => Stream.value(const <Project>[])),
      activeProjectProgressProvider.overrideWith((ref) async => null),
      weekForecastProvider.overrideWith(
          (ref) async => const WeekForecast.unavailable('Not under test.')),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark.copyWith(platform: platform),
      home: const Scaffold(body: PlannerScreen()),
    ),
  ));
  // Fixed pumps: the planner's sky clock never lets the tree settle.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  setUpAll(() => registerFallbackValue(''));

  testWidgets('every column starts where its header does, on every row',
      (tester) async {
    await _pumpTonight(tester);

    final rows = find.byType(Candidate);
    expect(rows, findsNWidgets(4));
    final header = find.byType(CandidateHeader);
    expect(header, findsOneWidget);

    double headerLeft(String label) => tester
        .getTopLeft(find.descendant(of: header, matching: find.text(label)))
        .dx;
    final transitX = headerLeft('TRANSIT');
    final imageableX = headerLeft('IMAGEABLE');
    final windowX = headerLeft('WINDOW TONIGHT');

    double? actionRight;
    for (var i = 0; i < 4; i++) {
      final row = rows.at(i);
      final readouts = find.descendant(of: row, matching: find.byType(Readout));
      expect(tester.getTopLeft(readouts.at(0)).dx, transitX,
          reason: 'row $i transit column');
      expect(tester.getTopLeft(readouts.at(1)).dx, imageableX,
          reason: 'row $i imageable column');
      expect(
        tester
            .getTopLeft(find.descendant(
                of: row, matching: find.byType(CandidateWindowBar)))
            .dx,
        windowX,
        reason: 'row $i window column',
      );
      final right = tester
          .getTopRight(
              find.descendant(of: row, matching: find.byType(SkotiqButton)))
          .dx;
      actionRight ??= right;
      expect(right, actionRight, reason: 'row $i action slot');
    }

    // The selected row carries the wider button and still lines up.
    expect(find.widgetWithText(SkotiqButton, 'Image tonight'), findsOneWidget);

    await settleProviderTeardown(tester);
  });

  testWidgets('a candidate row stays two lines and at most 64px tall',
      (tester) async {
    // Windows, the imaging laptop's platform. On a touch platform the row's
    // button grows to the 48px touch floor and the row grows with it.
    await _pumpTonight(tester, platform: TargetPlatform.windows);

    for (final element in find.byType(Candidate).evaluate()) {
      final height = tester.getSize(find.byWidget(element.widget)).height;
      expect(height, lessThanOrEqualTo(64));
      expect(height, greaterThanOrEqualTo(56));
    }
    // Name over detail line: two lines, not wrapped or squeezed onto one.
    final name = tester.getRect(find.text('M33'));
    final detail = tester.getRect(find.textContaining('62.1'));
    expect(detail.top, greaterThanOrEqualTo(name.bottom));

    await settleProviderTeardown(tester);
  });
}
