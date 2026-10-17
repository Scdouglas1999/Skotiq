// Widget tests for the Plan Tonight screen (PlannerScreen).
//
// We avoid spinning up the full Riverpod graph (database, FFI backend,
// catalog loader). Instead we override the providers the planner reads:
//   - appSettingsProvider: provide a non-zero location.
//   - tonightSuggestionsProvider: return a deterministic in-memory list.
//
// The screen is mounted inside a GoRouter so `context.go(...)` reaches a real
// router, and the /framing route is a stub that records the navigated URL.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/provider_teardown.dart';

class _TestAppSettingsNotifier extends AppSettingsNotifier {
  final AppSettingsState _settings;
  _TestAppSettingsNotifier(this._settings);

  @override
  Future<AppSettingsState> build() async => _settings;
}

TargetSuggestion _suggestion({
  required int id,
  required String name,
  String? catalogId,
  String? objectType,
  String? constellation,
  double score = 80.0,
  double magnitude = 8.0,
  double peakAlt = 60.0,
  double moonDistance = 90.0,
  double raHours = 5.0,
  double decDegrees = -5.0,
  double? sizeArcmin,
}) {
  return TargetSuggestion(
    targetId: id,
    targetName: name,
    catalogId: catalogId,
    raHours: raHours,
    decDegrees: decDegrees,
    totalScore: score,
    visibility: TargetVisibilityInfo(
      currentAltitude: peakAlt - 5,
      currentAzimuth: 180.0,
      transitAltitude: peakAlt,
      airmass: 1.2,
      moonDistance: moonDistance,
      peakAltitude: peakAlt,
      hoursAboveMinAlt: 6.0,
    ),
    reasoning: 'Stable at high altitude with good moon separation.',
    objectType: objectType,
    magnitude: magnitude,
    constellation: constellation,
    sizeArcmin: sizeArcmin,
  );
}

/// Five candidates with a controlled spread of sizes for size filter/sort
/// tests: 0.5' planetary nebula, 8' globular, 30' nebula, 180' (3°) Andromeda,
/// and one with no recorded size (must sink under size sort and be excluded
/// by an active size filter).
List<TargetSuggestion> _sizedCandidates() {
  return [
    _suggestion(
      id: 100,
      name: 'M57 Ring',
      catalogId: 'M57',
      objectType: 'Planetary Nebula',
      constellation: 'Lyr',
      score: 70.0,
      sizeArcmin: 0.5,
    ),
    _suggestion(
      id: 101,
      name: 'M13',
      catalogId: 'M13',
      objectType: 'Globular Cluster',
      constellation: 'Her',
      score: 75.0,
      sizeArcmin: 8.0,
    ),
    _suggestion(
      id: 102,
      name: 'M27 Dumbbell',
      catalogId: 'M27',
      objectType: 'Planetary Nebula',
      constellation: 'Vul',
      score: 72.0,
      sizeArcmin: 30.0,
    ),
    _suggestion(
      id: 103,
      name: 'M31 Andromeda',
      catalogId: 'M31',
      objectType: 'Galaxy',
      constellation: 'And',
      score: 90.0,
      sizeArcmin: 180.0,
    ),
    _suggestion(
      id: 104,
      name: 'Mystery target',
      catalogId: 'X-1',
      objectType: 'Galaxy',
      constellation: 'Ori',
      score: 60.0,
      // no sizeArcmin → must be excluded by any active size filter
      // and sink to the bottom under size sort
    ),
  ];
}

List<TargetSuggestion> _tenCandidates() {
  return [
    _suggestion(
      id: 1,
      name: 'NGC 7000',
      catalogId: 'NGC 7000',
      objectType: 'Emission Nebula',
      constellation: 'Cyg',
      score: 92.0,
    ),
    _suggestion(
      id: 2,
      name: 'M31 Andromeda',
      catalogId: 'M31',
      objectType: 'Galaxy',
      constellation: 'And',
      score: 88.0,
      raHours: 0.7,
      decDegrees: 41.3,
    ),
    _suggestion(
      id: 3,
      name: 'M42 Orion',
      catalogId: 'M42',
      objectType: 'Emission Nebula',
      constellation: 'Ori',
      score: 84.0,
      raHours: 5.6,
      decDegrees: -5.4,
    ),
    _suggestion(
      id: 4,
      name: 'M81 Bode',
      catalogId: 'M81',
      objectType: 'Galaxy',
      constellation: 'UMa',
      score: 80.0,
    ),
    _suggestion(
      id: 5,
      name: 'M13',
      catalogId: 'M13',
      objectType: 'Globular Cluster',
      constellation: 'Her',
      score: 78.0,
    ),
    _suggestion(
      id: 6,
      name: 'M27 Dumbbell',
      catalogId: 'M27',
      objectType: 'Planetary Nebula',
      constellation: 'Vul',
      score: 74.0,
    ),
    _suggestion(
      id: 7,
      name: 'M101 Pinwheel',
      catalogId: 'M101',
      objectType: 'Galaxy',
      constellation: 'UMa',
      score: 70.0,
    ),
    _suggestion(
      id: 8,
      name: 'NGC 6960 Veil',
      catalogId: 'NGC 6960',
      objectType: 'Supernova Remnant',
      constellation: 'Cyg',
      score: 68.0,
    ),
    _suggestion(
      id: 9,
      name: 'IC 1396',
      catalogId: 'IC 1396',
      objectType: 'Emission Nebula',
      constellation: 'Cep',
      score: 66.0,
    ),
    _suggestion(
      id: 10,
      name: 'M51 Whirlpool',
      catalogId: 'M51',
      objectType: 'Galaxy',
      constellation: 'CVn',
      score: 64.0,
    ),
  ];
}

Future<void> _pumpPlanner(
  WidgetTester tester, {
  required List<TargetSuggestion> candidates,
  required ValueChanged<String> onFramingNavigated,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1024);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final router = GoRouter(
    initialLocation: '/planner',
    routes: [
      GoRoute(
        path: '/planner',
        builder: (context, state) => const PlannerScreen(),
      ),
      GoRoute(
        // The planner uses `context.goNamed('framing')` (added with the
        // stash@{1} UI), so the test router must register the route under
        // that name — otherwise go_router throws
        // "unknown route name: framing".
        name: 'framing',
        path: '/framing',
        builder: (context, state) {
          onFramingNavigated(state.uri.toString());
          return const Scaffold(body: Text('FRAMING STUB'));
        },
      ),
      GoRoute(
        path: '/sequencer',
        builder: (context, state) => const Scaffold(body: Text('SEQ STUB')),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const Scaffold(body: Text('SETTINGS')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        appSettingsProvider.overrideWith(
          () => _TestAppSettingsNotifier(
            const AppSettingsState(latitude: 40.0, longitude: -75.0),
          ),
        ),
        tonightSuggestionsProvider.overrideWith((ref) async => candidates),
      ],
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );

  // Allow the suggestion future + post-frame callbacks to settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders more than 3 candidates when 10 are available',
      (tester) async {
    await _pumpPlanner(
      tester,
      candidates: _tenCandidates(),
      onFramingNavigated: (_) {},
    );

    // The candidate list header reports the count after filtering.
    // 06 §Plan restates the count as the list's eyebrow column header.
    expect(find.textContaining('10 CANDIDATES'), findsOneWidget);

    // All ten candidates should be rendered (default page size is 25).
    expect(find.text('NGC 7000'), findsAtLeastNWidgets(1));
    expect(find.text('M31 Andromeda'), findsOneWidget);
    expect(find.text('M42 Orion'), findsOneWidget);
    expect(find.text('M81 Bode'), findsOneWidget);
    expect(find.text('M13'), findsOneWidget);
    expect(find.text('M27 Dumbbell'), findsOneWidget);
    expect(find.text('M101 Pinwheel'), findsOneWidget);
    expect(find.text('NGC 6960 Veil'), findsOneWidget);
    expect(find.text('IC 1396'), findsOneWidget);
    expect(find.text('M51 Whirlpool'), findsOneWidget);

    await settleProviderTeardown(tester);
  });

  testWidgets('search field narrows the visible candidate list',
      (tester) async {
    await _pumpPlanner(
      tester,
      candidates: _tenCandidates(),
      onFramingNavigated: (_) {},
    );

    final searchField = find.byType(TextField).first;
    expect(searchField, findsOneWidget);
    await tester.enterText(searchField, 'whirlpool');
    await tester.pump();

    // The candidate list header reports the filtered count (the primary
    // recommendation card above the list is intentionally unaffected — it
    // always shows tonight's globally-best target).
    expect(find.textContaining('1 CANDIDATE'), findsOneWidget);
    // M51 (the only match) appears in the list.
    expect(find.text('M51 Whirlpool'), findsAtLeastNWidgets(1));
    // Other candidate-list names disappear from the rendered tree (the
    // primary card may still show its own; that's expected).
    expect(find.text('M31 Andromeda'), findsNothing);
    expect(find.text('M13'), findsNothing);
    expect(find.text('M81 Bode'), findsNothing);

    await settleProviderTeardown(tester);
  });

  test('object-type filter removes non-matching candidates', () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        tonightSuggestionsProvider.overrideWith(
          (ref) async => _tenCandidates(),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Hold the autoDispose chain alive while we drive the filter directly.
    final sub = container.listen<AsyncValue<List<TargetSuggestion>>>(
      plannerFilteredSuggestionsProvider,
      (_, __) {},
    );
    addTearDown(sub.close);

    // Resolve the upstream future before reading the derived provider.
    await container.read(tonightSuggestionsProvider.future);

    container.read(suggestionFilterProvider.notifier).state =
        const SuggestionFilterState(selectedObjectTypes: {'galaxy'});

    final filtered =
        container.read(plannerFilteredSuggestionsProvider).valueOrNull ??
            const [];
    final names = filtered.map((s) => s.targetName).toSet();
    expect(
        names,
        containsAll(<String>[
          'M31 Andromeda',
          'M81 Bode',
          'M101 Pinwheel',
          'M51 Whirlpool',
        ]));
    // Nebulae / clusters / SNRs must be excluded.
    expect(names, isNot(contains('NGC 7000')));
    expect(names, isNot(contains('M42 Orion')));
    expect(names, isNot(contains('M13')));
    expect(names, isNot(contains('NGC 6960 Veil')));
  });

  testWidgets('Send to Framing navigates and seeds the framing target',
      (tester) async {
    // Post-stash@{1}, the planner no longer encodes the target in URL
    // query params. It does `ref.read(framingProvider.notifier)
    // .setTargetSuggestion(target)` and then `context.goNamed('framing')`.
    // The test therefore asserts BOTH: navigation reaches /framing AND
    // the framing provider was seeded with the right target.
    String? capturedUrl;
    await _pumpPlanner(
      tester,
      candidates: _tenCandidates(),
      onFramingNavigated: (url) => capturedUrl = url,
    );

    // 06 §Plan moves framing onto the detail column, which describes the
    // SELECTED candidate — NGC 7000, the highest-scoring one, by default. One
    // button instead of one per row, acting on the target the column is
    // describing.
    final sendButton = find.widgetWithText(SkotiqButton, 'Frame it');
    expect(sendButton, findsOneWidget);
    await tester.ensureVisible(sendButton);
    await tester.pump();
    await tester.tap(sendButton);
    await tester.pumpAndSettle();

    expect(capturedUrl, isNotNull);
    final uri = Uri.parse(capturedUrl!);
    expect(uri.path, '/framing');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final framing = container.read(framingProvider);
    expect(framing.sourceSuggestion?.targetName, 'NGC 7000');
    expect(framing.target?.name, 'NGC 7000');
    expect(framing.target!.raHours, closeTo(5.0, 1e-3));
    expect(framing.target!.decDegrees, closeTo(-5.0, 1e-3));

    await settleProviderTeardown(tester);
  });

  test('size filter narrows the candidate list to the requested range',
      () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        tonightSuggestionsProvider.overrideWith(
          (ref) async => _sizedCandidates(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen<AsyncValue<List<TargetSuggestion>>>(
      plannerFilteredSuggestionsProvider,
      (_, __) {},
    );
    addTearDown(sub.close);

    await container.read(tonightSuggestionsProvider.future);

    // Window: 5' to 60' inclusive. Keeps M13 (8') and M27 (30').
    // Excludes M57 (0.5', too small), M31 (180', too large), and the
    // sizeless Mystery target.
    container.read(suggestionFilterProvider.notifier).state =
        const SuggestionFilterState(
      minSizeArcmin: 5.0,
      maxSizeArcmin: 60.0,
    );

    final filtered =
        container.read(plannerFilteredSuggestionsProvider).valueOrNull ??
            const [];
    final names = filtered.map((s) => s.targetName).toSet();
    expect(names, equals(<String>{'M13', 'M27 Dumbbell'}));

    // The exclusion breakdown must surface the size filter so the
    // empty-state hint can render it as a top-impact filter.
    container.read(suggestionFilterProvider.notifier).state =
        const SuggestionFilterState(minSizeArcmin: 1000.0);
    final breakdown = container.read(plannerFilterExclusionProvider);
    expect(breakdown.passed, 0);
    expect(
      breakdown.excludedByFilter.keys.any((k) => k.startsWith('Min size')),
      isTrue,
    );
  });

  test('size sort orders by descending size with nulls sinking', () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        tonightSuggestionsProvider.overrideWith(
          (ref) async => _sizedCandidates(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen<AsyncValue<List<TargetSuggestion>>>(
      plannerFilteredSuggestionsProvider,
      (_, __) {},
    );
    addTearDown(sub.close);

    await container.read(tonightSuggestionsProvider.future);

    container.read(suggestionFilterProvider.notifier).state =
        const SuggestionFilterState(plannerSort: PlannerSortMode.size);

    final sorted =
        container.read(plannerFilteredSuggestionsProvider).valueOrNull ??
            const [];
    final names = sorted.map((s) => s.targetName).toList();

    // M31 (180') → M27 (30') → M13 (8') → M57 (0.5') → Mystery (null)
    expect(
        names,
        equals(<String>[
          'M31 Andromeda',
          'M27 Dumbbell',
          'M13',
          'M57 Ring',
          'Mystery target',
        ]));
  });
}
