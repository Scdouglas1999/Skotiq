// Pins what Plan > Targets shows of the autopilot: which decision the bar
// reads (live or preview) and how a settings edit saves (one at a time, put
// back when the save fails, one error message until a save succeeds).

import 'dart:async';

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
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../scheduler_test_doubles.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {
  _MockNetworkBackend() {
    when(() => scheme).thenReturn('https');
    when(() => serverHost).thenReturn('host.local');
    when(() => serverPort).thenReturn(8080);
    when(() => pinnedFingerprint).thenReturn(null);
  }
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Map<String, dynamic> _remoteSchedulerState() => {
      'status': {'state': SchedulerState.idle.name},
      'decision': {
        'score': 0,
        'reasoning': <String>[],
        'scoredCandidates': <Object?>[
          {
            'targetId': 1,
            'targetName': 'M42',
            'totalScore': 1.0,
            'factors': <Object?>[],
            'hardConstraintFailed': false,
            'rejectionReasons': <Object?>[],
          },
        ],
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

List<Override> _commonOverrides({Future<SchedulerDecision>? preview}) => [
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
        (ref) => preview ?? Completer<SchedulerDecision>().future,
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

SchedulerDecision _decisionNaming(String rejectedName) => decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [scoreFor(id: 1, name: 'NGC 7000', total: 2.4)],
      rejected: [
        rejectionFor(
          id: 2,
          name: rejectedName,
          score: 1.1,
          primaryReason: 'below horizon',
        ),
      ],
    );

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

  // Which decision the bar reads on the machine that runs the autopilot:
  // idle prefers the preview, running prefers the live decision, and each
  // falls back to the other.
  final mergeCases =
      <({SchedulerState state, bool live, bool preview, String shows})>[
    (state: SchedulerState.idle, live: true, preview: true, shows: 'Preview'),
    (state: SchedulerState.idle, live: true, preview: false, shows: 'Live'),
    (state: SchedulerState.idle, live: false, preview: true, shows: 'Preview'),
    (state: SchedulerState.running, live: true, preview: true, shows: 'Live'),
    (
      state: SchedulerState.running,
      live: false,
      preview: true,
      shows: 'Preview'
    ),
    (state: SchedulerState.running, live: true, preview: false, shows: 'Live'),
  ];
  for (final c in mergeCases) {
    testWidgets(
      '${c.state.name}, live ${c.live}, preview ${c.preview}: '
      'Why lists the ${c.shows.toLowerCase()} decision',
      (tester) async {
        _sizeView(tester);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              inMemoryDatabaseOverride(),
              ..._commonOverrides(
                preview: c.preview
                    ? Future.value(_decisionNaming('Preview target'))
                    : null,
              ),
              schedulerEngineProvider.overrideWithValue(
                buildTestSchedulerEngine(),
              ),
              schedulerStatusProvider.overrideWith(
                (ref) => FakeSchedulerStatusNotifier(
                  SchedulerStatus(state: c.state),
                ),
              ),
              currentSchedulerDecisionProvider.overrideWith(
                (ref) => FakeCurrentSchedulerDecisionNotifier(
                  c.live ? _decisionNaming('Live target') : null,
                ),
              ),
            ],
            child: MaterialApp(
              theme: SkotiqTheme.dark,
              home: const Scaffold(body: PlanTargetsTab()),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        await tester.tap(find.byKey(const ValueKey('autopilot-why')));
        await tester.pumpAndSettle();

        expect(find.text('${c.shows} target'), findsOneWidget);
        final other = c.shows == 'Live' ? 'Preview' : 'Live';
        expect(find.text('$other target'), findsNothing);
      },
    );
  }

  group('autopilot settings saves on a linked host', () {
    late _MockNetworkBackend backend;
    late List<Completer<Map<String, dynamic>>> saves;

    setUp(() {
      backend = _MockNetworkBackend();
      saves = [];
      when(backend.getSchedulerState).thenAnswer(
        (_) async => _remoteSchedulerState(),
      );
      when(() => backend.updateSchedulerConfig(any())).thenAnswer((_) {
        final save = Completer<Map<String, dynamic>>();
        saves.add(save);
        return save.future;
      });
    });

    Future<void> pumpTab(WidgetTester tester) async {
      _sizeView(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            ..._commonOverrides(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            schedulerEngineProvider.overrideWith(
              (ref) => throw StateError('remote client created an engine'),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: PlanTargetsTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('autopilot-settings')));
      await tester.pumpAndSettle();
    }

    double altitudeSlider(WidgetTester tester) =>
        tester.widget<SkotiqSlider>(find.byType(SkotiqSlider).first).value;

    void slideAltitude(WidgetTester tester, double value) => tester
        .widget<SkotiqSlider>(find.byType(SkotiqSlider).first)
        .onChanged!(value);

    testWidgets('a second edit waits for the first save', (tester) async {
      await pumpTab(tester);

      slideAltitude(tester, 2.5);
      await tester.pump();
      slideAltitude(tester, 3.0);
      await tester.pump();
      expect(altitudeSlider(tester), 3.0);
      expect(saves, hasLength(1));

      saves[0].complete(_remoteSchedulerState());
      await tester.pump();
      await tester.pump();
      expect(saves, hasLength(2));
      expect(altitudeSlider(tester), 3.0, reason: 'the newer edit still shows');
    });

    testWidgets(
      'a failed save puts the host settings back and says so once until a '
      'save succeeds',
      (tester) async {
        await pumpTab(tester);
        final hostAltitude = SchedulerConfig.defaults.weights.altitude;

        slideAltitude(tester, 2.5);
        await tester.pump();
        saves[0].completeError(StateError('host refused'));
        await tester.pumpAndSettle();
        expect(altitudeSlider(tester), hostAltitude);
        expect(
          find.textContaining('Could not save the autopilot settings'),
          findsOneWidget,
        );

        // Let the message go, then fail again: no second message.
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not save the autopilot settings'),
          findsNothing,
        );
        slideAltitude(tester, 2.0);
        await tester.pump();
        saves[1].completeError(StateError('host refused again'));
        await tester.pumpAndSettle();
        expect(altitudeSlider(tester), hostAltitude);
        expect(
          find.textContaining('Could not save the autopilot settings'),
          findsNothing,
        );

        // A good save re-arms the message.
        slideAltitude(tester, 2.2);
        await tester.pump();
        saves[2].complete(_remoteSchedulerState());
        await tester.pumpAndSettle();
        slideAltitude(tester, 2.4);
        await tester.pump();
        saves[3].completeError(StateError('host refused a third time'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not save the autopilot settings'),
          findsOneWidget,
        );
      },
    );
  });
}
