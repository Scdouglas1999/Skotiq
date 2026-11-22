// Pins the autopilot settings save on the machine that runs the autopilot
// (no linked host): what is stored, what the engine then runs on, and that a
// burst of edits saves every one in order with the last one in force. Also
// pins the linked-host poll: every 3 s while linked and in the foreground,
// stopped while in the background or after unlinking.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/planner/targets/plan_targets_tab.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart' as ndb;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../scheduler_test_doubles.dart';

/// The real store, recording each config it is asked to save.
class _RecordingStore extends SchedulerConfigStore {
  _RecordingStore(super.dao);

  final saved = <SchedulerConfig>[];

  @override
  Future<void> save(SchedulerConfig config) {
    saved.add(config);
    return super.save(config);
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {
  _MockNetworkBackend() {
    when(() => scheme).thenReturn('https');
    when(() => serverHost).thenReturn('host.local');
    when(() => serverPort).thenReturn(8080);
    when(() => pinnedFingerprint).thenReturn(null);
  }
}

class _LocalBackend extends Mock implements SkotiqBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

Map<String, dynamic> _remoteSchedulerState() => {
      'status': {'state': SchedulerState.idle.name},
      'decision': {
        'score': 0,
        'reasoning': <String>[],
        'scoredCandidates': <Object?>[],
        'rejected': <Object?>[],
        'evaluatedAt': DateTime.utc(2026, 7, 13).toIso8601String(),
        'isSwitch': false,
      },
      'config': SchedulerConfig.defaults.toStorageJson(),
      'readiness': const SchedulerStartReadiness(
        issues: [],
        available: true,
        solverRequired: true,
      ).toStorageJson(),
    };

List<Override> _commonOverrides() => [
      schedulerEngineReadyProvider.overrideWith(
        (ref) => ref.read(schedulerEngineProvider),
      ),
      schedulerStartReadinessProvider.overrideWithValue(
        const SchedulerStartReadiness(
          issues: [],
          available: true,
          solverRequired: true,
        ),
      ),
      schedulerAutoReevalProvider.overrideWith((ref) {}),
      planTargetsProvider.overrideWith((ref) => const AsyncValue.data([])),
      projectListProvider.overrideWith((ref) => Stream.value(const [])),
      unusedTargetsCountProvider.overrideWith((ref) async => 0),
      schedulerPreviewDecisionProvider.overrideWith(
        (ref) => Completer<SchedulerDecision>().future,
      ),
      allDbTargetsProvider.overrideWith(
        (ref) => const Stream<List<ndb.DbTarget>>.empty(),
      ),
      integrationGoalsStreamProvider.overrideWith(
        (ref) => const Stream<List<IntegrationGoal>>.empty(),
      ),
      targetConstraintsStreamProvider.overrideWith(
        (ref) => const Stream<List<TargetConstraint>>.empty(),
      ),
      integrationGoalProgressProvider.overrideWith(
        (ref, _) async => <IntegrationGoalProgress>[],
      ),
      allIntegrationGoalsProvider
          .overrideWith((ref) async => <IntegrationGoal>[]),
    ];

void _sizeView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('autopilot settings saved on this machine', () {
    late SchedulerEngine engine;
    late _RecordingStore store;

    Future<ProviderContainer> pumpTab(WidgetTester tester) async {
      _sizeView(tester);
      engine = buildTestSchedulerEngine();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            ..._commonOverrides(),
            schedulerEngineProvider.overrideWithValue(engine),
            schedulerConfigStoreProvider.overrideWith((ref) {
              return store = _RecordingStore(ref.watch(settingsDaoProvider));
            }),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: PlanTargetsTab()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('autopilot-settings')));
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
        tester.element(find.byType(PlanTargetsTab)),
      );
    }

    void slideAltitude(WidgetTester tester, double value) => tester
        .widget<SkotiqSlider>(find.byType(SkotiqSlider).first)
        .onChanged!(value);

    double altitudeSlider(WidgetTester tester) =>
        tester.widget<SkotiqSlider>(find.byType(SkotiqSlider).first).value;

    Future<Map<String, dynamic>> storedRow(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      final raw = await tester.runAsync(
        () => container
            .read(settingsDaoProvider)
            .read(StoreSettings.schedulerConfig),
      );
      expect(raw, isNotNull, reason: 'the edit is stored');
      return jsonDecode(raw!) as Map<String, dynamic>;
    }

    Future<void> settleSaves(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('one edit is stored, and the engine runs on it', (
      tester,
    ) async {
      final container = await pumpTab(tester);
      final expected = SchedulerConfig.defaults.copyWith(
        weights: SchedulerConfig.defaults.weights.copyWith(altitude: 2.5),
      );

      slideAltitude(tester, 2.5);
      await tester.pump();
      expect(engine.config, expected, reason: 'in force before it is saved');
      await settleSaves(tester);

      expect(store.saved, [expected]);
      expect(await storedRow(tester, container), {
        'hysteresisRatio': SchedulerConfig.defaults.hysteresisRatio,
        'minAltitudeDegrees': SchedulerConfig.defaults.minAltitudeDegrees,
        'weights': {
          'altitude': 2.5,
          'meridian': SchedulerConfig.defaults.weights.meridian,
          'moon': SchedulerConfig.defaults.weights.moon,
          'timeRemaining': SchedulerConfig.defaults.weights.timeRemaining,
          'filterCoverage': SchedulerConfig.defaults.weights.filterCoverage,
          'userPriority': SchedulerConfig.defaults.weights.userPriority,
        },
      });
      expect(engine.config, expected);
      expect(altitudeSlider(tester), 2.5);
      expect(container.read(schedulerConfigUserDirtyProvider), isTrue);
      final reread = await tester.runAsync(
        () => container.read(schedulerPersistedConfigProvider.future),
      );
      expect(reread, expected, reason: 'a restart reads the edit back');
    });

    testWidgets(
      'a burst of edits saves each one in order and the last one stays',
      (tester) async {
        final container = await pumpTab(tester);
        const values = [2.0, 2.2, 2.4, 2.6];
        for (final v in values) {
          slideAltitude(tester, v);
          await tester.pump();
        }
        expect(altitudeSlider(tester), 2.6);
        expect(engine.config.weights.altitude, 2.6);
        await settleSaves(tester);

        expect([for (final c in store.saved) c.weights.altitude], values);
        final row = await storedRow(tester, container);
        expect((row['weights'] as Map)['altitude'], 2.6);
        expect(engine.config.weights.altitude, 2.6);
        expect(altitudeSlider(tester), 2.6);
        expect(
          find.textContaining('Could not save the autopilot settings'),
          findsNothing,
        );
      },
    );
  });

  group('linked-host poll', () {
    late _MockNetworkBackend host;
    late _SwappableBackendNotifier notifier;
    late int reads;

    Future<void> pumpTab(WidgetTester tester) async {
      _sizeView(tester);
      reads = 0;
      host = _MockNetworkBackend();
      when(host.getSchedulerState).thenAnswer((_) async {
        reads++;
        return _remoteSchedulerState();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            ..._commonOverrides(),
            backendProvider.overrideWith((ref) {
              return notifier = _SwappableBackendNotifier(ref, host);
            }),
            schedulerEngineProvider.overrideWithValue(
              buildTestSchedulerEngine(),
            ),
            schedulerStatusProvider.overrideWith(
              (ref) => FakeSchedulerStatusNotifier(const SchedulerStatus()),
            ),
            currentSchedulerDecisionProvider.overrideWith(
              (ref) => FakeCurrentSchedulerDecisionNotifier(null),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: PlanTargetsTab()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<int> readsOver(WidgetTester tester, Duration span) async {
      final before = reads;
      await tester.pump(span);
      await tester.pump();
      return reads - before;
    }

    void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
      for (final s in states) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    testWidgets('polls every 3 s, stops in the background, resumes', (
      tester,
    ) async {
      await pumpTab(tester);
      expect(reads, greaterThan(0), reason: 'first read on open');

      expect(await readsOver(tester, const Duration(seconds: 3)), 1);
      expect(await readsOver(tester, const Duration(seconds: 3)), 1);

      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      for (var i = 0; i < 4; i++) {
        expect(await readsOver(tester, const Duration(seconds: 3)), 0);
      }

      lifecycle(tester, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(await readsOver(tester, const Duration(seconds: 3)), 1);
    });

    testWidgets('unlinking stops asking the old host', (tester) async {
      await pumpTab(tester);
      expect(await readsOver(tester, const Duration(seconds: 3)), 1);

      notifier.switchTo(_LocalBackend());
      await tester.pump();
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        expect(await readsOver(tester, const Duration(seconds: 3)), 0);
      }
    });
  });
}
