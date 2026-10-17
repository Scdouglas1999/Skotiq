import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:drift/native.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_planetarium/skotiq_planetarium.dart' as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';

class _FakeSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        latitude: 40,
        longitude: -75,
      );
}

TargetSuggestion _suggestion() {
  return TargetSuggestion(
    targetId: 42,
    targetName: 'M51',
    catalogId: 'M51',
    raHours: 13.5,
    decDegrees: 47.2,
    totalScore: 91,
    reasoning: 'Excellent altitude tonight.',
    visibility: planetarium.TargetVisibilityInfo(
      currentAltitude: 72,
      currentAzimuth: 180,
      transitAltitude: 78,
      transitTime: DateTime(2026, 5, 22, 1, 22),
      airmass: 1.1,
      moonDistance: 100,
      hoursAboveMinAlt: 5,
    ),
  );
}

void main() {
  testWidgets('primary recommendation exposes framing and sequencer actions',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      appSettingsProvider.overrideWith(_FakeSettingsNotifier.new),
      activeEquipmentProfileProvider.overrideWithValue(
        const EquipmentProfileModel(
          id: 7,
          name: 'Backyard rig',
          focalLength: 600,
          aperture: 80,
          // A camera is required for Smart Night to resolve the sensor pixel
          // pitch (no exposure-context override is supplied in this test), which
          // in turn is required to compute exposure recommendations.
          cameraName: 'ZWO ASI2600MM Pro',
          filterNames: ['L'],
          defaultGain: 101,
          defaultOffset: 20,
        ),
      ),
      smartNightExposureContextProvider.overrideWith((ref) async => null),
      tonightSuggestionsProvider.overrideWith((ref) async => [_suggestion()]),
      planetarium.twilightTimesProvider
          .overrideWithValue(planetarium.TwilightTimes(
        astronomicalDusk: DateTime(2026, 5, 22, 21),
        astronomicalDawn: DateTime(2026, 5, 23, 5),
      )),
      planetarium.moonInfoProvider.overrideWithValue(
        const planetarium.MoonTimes(
          illumination: 22,
          phaseName: 'Waning Crescent',
        ),
      ),
      planetarium.observationTimeProvider.overrideWith(
        (ref) => planetarium.ObservationTimeNotifier()
          ..setTime(DateTime(2026, 5, 22, 20)),
      ),
    ]);
    var cleanedUp = false;
    Future<void> cleanup() async {
      if (cleanedUp) return;
      cleanedUp = true;
      container.dispose();
      await database.close();
    }

    addTearDown(cleanup);
    container
        .read(currentSequenceProvider.notifier)
        .createSequence(name: 'tonight');

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: SkotiqTheme.dark,
              home: const Scaffold(
                body: TonightCard(colors: SkotiqColors.dark),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/framing',
          name: 'framing',
          builder: (context, state) => const SizedBox.shrink(),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('M51'), findsWidgets);
    expect(find.byIcon(LucideIcons.frame), findsOneWidget);
    expect(find.byIcon(LucideIcons.listPlus), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.frame));
    await tester.pumpAndSettle();
    expect(container.read(framingProvider).target?.name, 'M51');
    expect(container.read(framingProvider).sourceSuggestion?.targetId, 42);

    router.go('/');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.listPlus));
    await tester.tap(find.byIcon(LucideIcons.listPlus));
    await tester.pumpAndSettle();

    final targets = container
        .read(currentSequenceProvider)!
        .nodes
        .values
        .whereType<TargetHeaderNode>()
        .toList();
    expect(
      targets,
      hasLength(1),
      reason: 'rapid taps must not append the recommendation twice',
    );
    expect(targets.single.targetName, 'M51');
    expect(targets.single.raHours, closeTo(13.5, 1e-6));
    expect(targets.single.decDegrees, closeTo(47.2, 1e-6));
    final smartExposureNodes = container
        .read(currentSequenceProvider)!
        .nodes
        .values
        .whereType<SmartExposureNode>()
        .toList();
    expect(smartExposureNodes, hasLength(1));
    expect(smartExposureNodes.single.plans, isNotEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await cleanup();
  });
}
