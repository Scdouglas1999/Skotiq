import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/dashboard/widgets/glass_card.dart'
    show DashboardGlassCard;
import 'package:skotiq_app/screens/dashboard/widgets/smart_night_prompt_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_planetarium/skotiq_planetarium.dart' as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';

class _AutoPromptOffSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        smartNightAutoPromptEnabled: false,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('suppresses the dashboard prompt when a pending draft exists',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        smartNightPromptGraceProvider.overrideWithValue(Duration.zero),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final now = DateTime.now();
    await container.read(smartNightDraftServiceProvider).savePending(
          profileId: '7',
          astronomicalDay:
              now.hour < 12 ? now.subtract(const Duration(days: 1)) : now,
          plan: _plan('M51'),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SmartNightPromptCard(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Build tonight\'s Smart Night plan?'), findsNothing);
    expect(find.text('Build Plan'), findsNothing);
  });

  testWidgets('hides the dashboard prompt when auto-prompt is disabled',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(_AutoPromptOffSettingsNotifier.new),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        smartNightPromptGraceProvider.overrideWithValue(Duration.zero),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SmartNightPromptCard(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Resume tonight\'s Smart Night plan?'), findsNothing);
    expect(find.text('Load Plan'), findsNothing);
  });

  testWidgets('overflow menu persists the auto-prompt opt-out', (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        smartNightPromptGraceProvider.overrideWithValue(Duration.zero),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SmartNightPromptCard(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(LucideIcons.moreVertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Don't ask again on connect"));
    await tester.pumpAndSettle();

    final settings = await container.read(appSettingsProvider.future);
    expect(settings.smartNightAutoPromptEnabled, isFalse);
    expect(find.text('Resume tonight\'s Smart Night plan?'), findsNothing);
  });

  testWidgets('waits through the equipment-ready grace period before showing',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SmartNightPromptCard(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Build tonight\'s plan?'), findsNothing);
    expect(find.text('Build Plan'), findsNothing);
  });

  testWidgets('the published band follows a text-scale rewrap', (tester) async {
    // A text-scale bump rewraps the card taller WITHOUT re-running the
    // positioning builder (nothing up there depends on the scaler), so the band
    // must be republished from a size-change notification, not only from the
    // builder.
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    var now = DateTime(2026, 8, 3, 21);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        smartNightPromptClockProvider.overrideWithValue(() => now),
        smartNightPromptGraceProvider.overrideWithValue(Duration.zero),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final scale = ValueNotifier(1.0);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: ValueListenableBuilder<double>(
            valueListenable: scale,
            builder: (context, value, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(value)),
              child: child!,
            ),
            child: const Scaffold(
              body: SmartNightPromptCard(colors: SkotiqColors.dark),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bandAt1 = container.read(floatingPromptReservedHeightProvider);
    expect(bandAt1, greaterThan(0));

    scale.value = 1.3;
    await tester.pumpAndSettle();
    final bandAt13 = container.read(floatingPromptReservedHeightProvider);
    expect(
      bandAt13,
      greaterThan(bandAt1),
      reason: 'the card rewrapped taller; a frozen band leaves the last '
          'dashboard row stuck under the prompt at accessibility scales',
    );

    scale.value = 1.0;
    await tester.pumpAndSettle();
    expect(
      container.read(floatingPromptReservedHeightProvider),
      moreOrLessEquals(bandAt1, epsilon: 1.0),
    );
  });

  testWidgets('a same-frame remount keeps the live band claim', (tester) async {
    // Post-frame publishes run inside the frame and dispose microtasks after
    // it, so a replacement instance claims first and the outgoing instance's
    // stale release must be a no-op — otherwise the reserve collapses to 0
    // under a card that is still floating.
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    var now = DateTime(2026, 8, 3, 21);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        smartNightPromptClockProvider.overrideWithValue(() => now),
        smartNightPromptGraceProvider.overrideWithValue(Duration.zero),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    Widget shell(Key key) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(
              body: KeyedSubtree(
                key: key,
                child: const SmartNightPromptCard(colors: SkotiqColors.dark),
              ),
            ),
          ),
        );

    await tester.pumpWidget(shell(const ValueKey('a')));
    await tester.pumpAndSettle();
    expect(
        container.read(floatingPromptReservedHeightProvider), greaterThan(0));

    // Re-key: the outgoing State disposes and a fresh one mounts in one frame.
    await tester.pumpWidget(shell(const ValueKey('b')));
    await tester.pumpAndSettle();

    expect(find.text('Build tonight\'s plan?'), findsOneWidget);
    expect(
      container.read(floatingPromptReservedHeightProvider),
      greaterThan(0),
      reason: 'the stale dispose release wiped the live claim',
    );
  });

  testWidgets(
      'unmounting the showing card mid-frame releases its band claim '
      'without a modify-during-build error', (tester) async {
    // Element unmount runs inside finalizeTree, where a synchronous provider
    // write trips riverpod's modify-during-build guard. The release must land
    // after the frame — and the claim must not leak, or the reserve sticks
    // under a card that is gone.
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    var now = DateTime(2026, 8, 3, 21);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        smartNightPromptClockProvider.overrideWithValue(() => now),
        smartNightPromptGraceProvider.overrideWithValue(Duration.zero),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final show = ValueNotifier(true);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: show,
              builder: (context, value, _) => value
                  ? const SmartNightPromptCard(colors: SkotiqColors.dark)
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Build tonight\'s plan?'), findsOneWidget);
    expect(container.read(smartNightAutoPromptShowingProvider), isTrue);

    // Remove the card by an ordinary rebuild — the provider SCOPE stays.
    show.value = false;
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'dispose must not write a provider during finalizeTree');
    expect(
      container.read(floatingPromptOwnersProvider),
      isEmpty,
      reason: 'the band claim must not outlive the card',
    );
  });

  testWidgets('shows the prompt once the equipment-ready grace has elapsed',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    // A MOVING clock. Against a cached `Provider<DateTime>` the measured
    // elapsed time is pinned at zero and the grace never expires, however long
    // the operator waits.
    var now = DateTime(2026, 8, 3, 21);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        smartNightPromptClockProvider.overrideWithValue(() => now),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SmartNightPromptCard(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Build tonight\'s plan?'), findsNothing);

    now = now.add(const Duration(seconds: 61));
    // Fires the grace timer the card armed, which is the only thing that wakes
    // it up; without it the operator sits on a dashboard that never changes.
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();

    expect(find.text('Build tonight\'s plan?'), findsOneWidget);
    expect(find.text('Plan tonight'), findsOneWidget);
    expect(container.read(smartNightAutoPromptShowingProvider), isTrue);

    // The reserve must be the band the SHOWING card actually occupies — its
    // rendered height plus the inset it floats above — because no constant can
    // cover a 108px card, a ~200px card, and a phone nav inset at once.
    // Settled, the card sits flush above its inset, so the band equals viewport
    // bottom minus the card's top edge.
    final cardTop = tester.getTopLeft(find.byType(DashboardGlassCard)).dy;
    final viewportBottom =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(
      container.read(floatingPromptReservedHeightProvider),
      moreOrLessEquals(viewportBottom - cardTop, epsilon: 1.0),
    );

    // Nothing in this test connects a device — the gate is optics-only, which
    // is deliberate (planning indoors before the gear is powered on is a real
    // use). So the card must not claim otherwise: a "Hardware ready" headline
    // renders directly beside a Readiness panel reading Camera/Mount/Guider
    // Disconnected and a 0/5 device count.
    expect(
      find.textContaining('Hardware', findRichText: true),
      findsNothing,
      reason: 'the prompt must not assert hardware state it never checked',
    );
  });

  testWidgets('the production clock advances the grace window', (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        // Deliberately does NOT override smartNightPromptClockProvider: this is
        // the regression guard for the cached `Provider<DateTime>` that pinned
        // the measured elapsed time at zero, so the shipped card could never
        // clear its own grace and the prompt was unreachable in the real app.
        smartNightPromptGraceProvider
            .overrideWithValue(const Duration(milliseconds: 200)),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SmartNightPromptCard(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Build tonight\'s plan?'), findsNothing);

    // Real wall-clock time has to pass, because the card measures the grace
    // against DateTime.now() rather than the test's fake async clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Build tonight\'s plan?'), findsOneWidget);
  });

  testWidgets(
      'hides the prompt when the active equipment profile is incomplete',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        smartNightPromptGraceProvider.overrideWithValue(Duration.zero),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Incomplete rig',
            focalLength: 600,
            aperture: 0,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SmartNightPromptCard(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Build tonight\'s plan?'), findsNothing);
    expect(find.text('Build Plan'), findsNothing);
  });

  testWidgets('suppresses the dashboard prompt while a sequence is active',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        sequenceExecutionStateProvider.overrideWith(
          (ref) => SequenceExecutionState.running,
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final now = DateTime.now();
    await container.read(smartNightDraftServiceProvider).savePending(
          profileId: '7',
          astronomicalDay:
              now.hour < 12 ? now.subtract(const Duration(days: 1)) : now,
          plan: _plan('M51'),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SmartNightPromptCard(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Resume tonight\'s Smart Night plan?'), findsNothing);
    expect(find.text('Load Plan'), findsNothing);
  });
}

SmartNightPlan _plan(String targetName) {
  final root = InstructionSetNode(
    id: 'root',
    name: 'Smart Night Root',
    childIds: const ['target'],
  );
  final target = TargetHeaderNode(
    id: 'target',
    name: targetName,
    targetName: targetName,
    raHours: 13.5,
    decDegrees: 47.2,
    parentId: 'root',
  );
  final start = DateTime.now();
  final end = start.add(const Duration(hours: 5));
  return SmartNightPlan(
    sequence: Sequence.create(
      name: 'Smart Night $targetName',
      rootNodeId: 'root',
      nodes: {
        root.id: root,
        target.id: target,
      },
    ),
    plannedTargets: [
      SmartNightPlannedTarget(
        suggestion: TargetSuggestion(
          targetId: 42,
          targetName: targetName,
          catalogId: targetName,
          raHours: 13.5,
          decDegrees: 47.2,
          totalScore: 91,
          reasoning: 'Excellent tonight.',
          visibility: planetarium.TargetVisibilityInfo(
            currentAltitude: 72,
            currentAzimuth: 180,
            transitAltitude: 78,
            transitTime: start.add(const Duration(hours: 2)),
            airmass: 1.1,
            moonDistance: 100,
            hoursAboveMinAlt: 5,
          ),
        ),
        windowStart: start,
        windowEnd: end,
        filterPlans: const [
          SmartNightFilterPlan(
            filterName: 'L',
            count: 12,
            durationSecs: 120,
          ),
        ],
        integrationSecs: 1440,
        rationale: 'Best target tonight.',
      ),
    ],
    totalIntegrationSecs: 1440,
    estimatedWallClockSecs: 1800,
    warnings: const [],
    strategy: SmartNightStrategy.autoLrgb,
    settings: const SmartNightSettings(),
    context: SmartNightContext(windowStart: start, windowEnd: end),
  );
}
