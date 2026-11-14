// The Overview blocks for the plan's optional parts: the sky-brightness
// exposure, the Target Scheduler, its conditions swap and the live-stacking
// broadcast. Each block's states, and the tab showing each only while the
// run uses that part.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:skotiq_app/screens/night_control/data/plan/scheduler_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/run_grading_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/overview_sections.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/overview_tab.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/run_sections.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';
import 'panel_test_support.dart';

final _now = DateTime.utc(2026, 10, 18, 4, 30);

AdaptiveExposureEvent _adapted({
  AdaptiveExposureReason reason = AdaptiveExposureReason.adapted,
  double adapted = 120,
}) =>
    AdaptiveExposureEvent(
      nodeId: 'exp-1',
      adaptedSecs: adapted,
      nominalSecs: 180,
      skyBrightnessMag: 20.314,
      filter: 'Ha',
      reason: reason,
      receivedAt: _now,
    );

SchedulerDecisionView _decision({String? picked = 'M 33'}) =>
    SchedulerDecisionView(
      time: DateTime(2026, 10, 17, 23, 12),
      decisionCounter: 4,
      pickedTargetName: picked,
      pickedScore: picked == null ? null : 74.4,
      scores: <SchedulerScoreEntry>[
        if (picked != null)
          const SchedulerScoreEntry(
            targetId: 't1',
            targetName: 'M 33',
            totalScore: 74.4,
            runnable: true,
          ),
        const SchedulerScoreEntry(
          targetId: 't2',
          targetName: 'NGC 891',
          totalScore: 61.2,
          runnable: true,
        ),
        const SchedulerScoreEntry(
          targetId: 't3',
          targetName: 'IC 1805',
          totalScore: 0,
          runnable: false,
          reason: 'below 30° altitude',
        ),
      ],
    );

AdaptiveSwapSnapshot _swap({DateTime? scoredAt, String? kind}) =>
    AdaptiveSwapSnapshot(
      score: ConditionsScore(
        score: 64,
        generatedAt: scoredAt ?? _now.subtract(const Duration(minutes: 2)),
      ),
      state: AdaptiveSwapRuntimeState(
        currentTier: 'medium',
        lastDecisionKind: kind,
        lastDecisionReason: 'M 33 stays above the medium floor.',
        lastSwapAt: _now.subtract(const Duration(minutes: 1)),
        lastSwapFromTargetId: 'hdr-1',
        lastSwapToTargetId: 'hdr-2',
        configuredThreshold: 50,
        configuredHysteresisSecs: 180,
      ),
    );

const _broadcast = LiveBroadcast(
  isPublic: false,
  stackMethod: 'Average',
  target: 'M 33',
  frames: 14,
  integrationSecs: 840,
  viewers: 3,
  reach: LiveBroadcastReach.open,
  pageUrl: 'http://192.168.1.20:8080/broadcast',
  token: 's3cret',
);

Future<void> _pumpSection(WidgetTester tester, Widget section) => pumpPanel(
      tester,
      overrides: const [],
      child: SingleChildScrollView(child: section),
    );

void main() {
  group('adaptive exposure', () {
    testWidgets('shows the exposure the sky made of the plan', (tester) async {
      await _pumpSection(
        tester,
        NightAdaptiveExposureSection(decision: _adapted()),
      );
      expect(find.text('Adaptive exposure'), findsOneWidget);
      expect(find.text('Adapted to the sky'), findsOneWidget);
      expect(find.text('Exposure · Ha'), findsOneWidget);
      expect(find.text('2m (plan 3m)'), findsOneWidget);
      expect(find.text('20.31 mag/arcsec²'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a clamped exposure is flagged', (tester) async {
      await _pumpSection(
        tester,
        NightAdaptiveExposureSection(
          decision: _adapted(reason: AdaptiveExposureReason.clampedMax),
        ),
      );
      expect(find.text('At the longest allowed'), findsOneWidget);
    });
  });

  group('scheduler', () {
    testWidgets('before its first pick it says what it will do',
        (tester) async {
      await _pumpSection(
        tester,
        const NightSchedulerSection(decision: null, minScore: 30),
      );
      expect(find.text('Scheduler'), findsOneWidget);
      expect(
        find.text('Picks the best target when the plan reaches it.'),
        findsOneWidget,
      );
    });

    testWidgets('a pick lists the target and the candidates it weighed',
        (tester) async {
      await _pumpSection(
        tester,
        NightSchedulerSection(decision: _decision(), minScore: 30),
      );
      expect(find.text('pick 4 at 23:12'), findsOneWidget);
      expect(find.text('Picked M 33'), findsOneWidget);
      expect(find.text('74'), findsOneWidget);
      expect(find.text('NGC 891'), findsOneWidget);
      expect(find.text('61'), findsOneWidget);
      expect(find.text('below 30° altitude'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no runnable target says the floor', (tester) async {
      await _pumpSection(
        tester,
        NightSchedulerSection(decision: _decision(picked: null), minScore: 30),
      );
      expect(
        find.text('No target scored 30 or more, so none was run.'),
        findsOneWidget,
      );
    });

    testWidgets('a long target name gives way to the value', (tester) async {
      final long = SchedulerDecisionView(
        time: DateTime(2026, 10, 17, 23, 12),
        decisionCounter: 1,
        pickedTargetName: null,
        pickedScore: null,
        scores: const <SchedulerScoreEntry>[
          SchedulerScoreEntry(
            targetId: 't',
            targetName: 'Sharpless 2-155 Cave Nebula and the dark lanes north',
            totalScore: 0,
            runnable: false,
            reason: 'moon 12° away, under the 40° minimum',
          ),
        ],
      );
      await _pumpSection(
        tester,
        NightSchedulerSection(decision: long, minScore: 30),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('conditions swap', () {
    Widget swap(AsyncValue<AdaptiveSwapSnapshot?> snapshot) =>
        NightConditionsSwapSection(
          snapshot: snapshot,
          swapBelow: 50,
          targetName: (id) => id == 'hdr-1' ? 'NGC 891' : 'M 33',
          now: _now,
        );

    testWidgets('loading', (tester) async {
      await _pumpSection(tester, swap(const AsyncLoading()));
      expect(find.text('Reading the conditions score…'), findsOneWidget);
    });

    testWidgets('an error says what failed', (tester) async {
      await _pumpSection(
        tester,
        swap(AsyncError(StateError('host unreachable'), StackTrace.empty)),
      );
      expect(
        find.textContaining('Could not read the swap state'),
        findsOneWidget,
      );
    });

    testWidgets('no score yet', (tester) async {
      await _pumpSection(tester, swap(const AsyncData(null)));
      expect(
        find.textContaining('No conditions score yet'),
        findsOneWidget,
      );
    });

    testWidgets('the score, the floor and the last swap by target name',
        (tester) async {
      await _pumpSection(
        tester,
        swap(AsyncData(_swap(kind: 'hold_current'))),
      );
      expect(find.text('Holding'), findsOneWidget);
      expect(find.text('64 · Degraded'), findsOneWidget);
      expect(find.text('medium · 50'), findsOneWidget);
      expect(find.text('1m ago · NGC 891 → M 33'), findsOneWidget);
      expect(find.text('in 2m'), findsOneWidget);
      expect(find.text('2m'), findsOneWidget);
      expect(find.text('M 33 stays above the medium floor.'), findsOneWidget);
    });

    testWidgets('an old score is called out', (tester) async {
      await _pumpSection(
        tester,
        swap(
          AsyncData(
            _swap(scoredAt: _now.subtract(const Duration(minutes: 9))),
          ),
        ),
      );
      expect(find.textContaining('The score is old'), findsOneWidget);
    });
  });

  group('broadcast', () {
    testWidgets('a private broadcast hides its token and copies the real link',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _pumpSection(
        tester,
        const NightBroadcastSection(broadcast: _broadcast),
      );
      expect(find.text('Live · private'), findsOneWidget);
      expect(find.text('14 frames · 14m'), findsOneWidget);
      expect(
        find.text('http://192.168.1.20:8080/broadcast?token=…'),
        findsOneWidget,
      );
      expect(find.textContaining('s3cret'), findsNothing);

      await tester.tap(find.text('Copy link'));
      await tester.pump();
      expect(copied, 'http://192.168.1.20:8080/broadcast?token=s3cret');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the QR code shows only on request', (tester) async {
      await _pumpSection(
        tester,
        const NightBroadcastSection(broadcast: _broadcast),
      );
      expect(find.byType(QrImageView), findsNothing);
      await tester.tap(find.text('Show QR'));
      await tester.pump();
      expect(
        find.bySemanticsLabel(
          'QR code for the broadcast link '
          'http://192.168.1.20:8080/broadcast?token=…',
        ),
        findsOneWidget,
      );
      expect(find.text('Hide QR'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with no server it says why nobody can watch', (tester) async {
      await _pumpSection(
        tester,
        const NightBroadcastSection(
          broadcast: LiveBroadcast(
            isPublic: true,
            stackMethod: 'Average',
            frames: 2,
            integrationSecs: 60,
            viewers: 0,
            reach: LiveBroadcastReach.serverOff,
          ),
        ),
      );
      expect(find.textContaining('Remote access is off'), findsOneWidget);
      expect(find.text('Copy link'), findsNothing);
      expect(find.text('Show QR'), findsNothing);
    });
  });

  group('Overview', () {
    final scheduler = TargetSchedulerNode(swapOnConditionsBelow: 50);

    testWidgets('a plain run shows none of them', (tester) async {
      await pumpPanel(
        tester,
        child: const NightOverviewTab(),
        overrides: panelOverrides(board: NightFixtures.running()),
      );
      expect(find.byType(NightAdaptiveExposureSection), findsNothing);
      expect(find.byType(NightSchedulerSection), findsNothing);
      expect(find.byType(NightConditionsSwapSection), findsNothing);
      expect(find.byType(NightBroadcastSection), findsNothing);
    });

    testWidgets('each shows while the run uses its part', (tester) async {
      await pumpPanel(
        tester,
        size: const Size(300, 2400),
        child: const NightOverviewTab(),
        overrides: <Override>[
          ...panelOverrides(board: NightFixtures.running()),
          nightAdaptiveExposureProvider.overrideWithValue(_adapted()),
          nightPlanSchedulerProvider.overrideWithValue(scheduler),
          latestSchedulerDecisionProvider.overrideWithValue(_decision()),
          adaptiveSwapSnapshotProvider.overrideWith(
            (ref) async => _swap(kind: 'hold_current'),
          ),
          liveBroadcastProvider.overrideWithValue(_broadcast),
        ],
      );
      await tester.pump();
      expect(find.text('Adaptive exposure'), findsOneWidget);
      expect(find.text('Scheduler'), findsOneWidget);
      expect(find.text('Conditions swap'), findsOneWidget);
      expect(find.text('Broadcast'), findsOneWidget);
      // Right after the session's counts.
      final session = tester.getTopLeft(find.byType(NightSessionSection)).dy;
      final adaptive =
          tester.getTopLeft(find.byType(NightAdaptiveExposureSection)).dy;
      final equipment =
          tester.getTopLeft(find.byType(NightEquipmentSection)).dy;
      expect(adaptive, greaterThan(session));
      expect(adaptive, lessThan(equipment));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a scheduler without the swap shows no swap block',
        (tester) async {
      await pumpPanel(
        tester,
        child: const NightOverviewTab(),
        overrides: <Override>[
          ...panelOverrides(board: NightFixtures.running()),
          nightPlanSchedulerProvider.overrideWithValue(TargetSchedulerNode()),
          latestSchedulerDecisionProvider.overrideWithValue(null),
        ],
      );
      expect(find.byType(NightSchedulerSection), findsOneWidget);
      expect(find.byType(NightConditionsSwapSection), findsNothing);
    });

    testWidgets('before a run the scheduler waits off screen', (tester) async {
      await pumpPanel(
        tester,
        child: const NightOverviewTab(),
        overrides: <Override>[
          ...panelOverrides(board: NightFixtures.ready()),
          nightPlanSchedulerProvider.overrideWithValue(scheduler),
        ],
      );
      expect(find.byType(NightSchedulerSection), findsNothing);
    });
  });

  testWidgets('the session names a streak of rejected frames', (tester) async {
    await _pumpSection(
      tester,
      const NightSessionSection(
        session: NightSessionVm(
          metrics: <MetricVm>[],
          rejectStreak: NightText(
            'nightSessionRejectedInARowReason',
            params: <String, String>{
              'count': '3',
              'reason': 'HFR 4.10 above 3.00',
            },
          ),
        ),
      ),
    );
    expect(
      find.text('3 frames rejected in a row: HFR 4.10 above 3.00'),
      findsOneWidget,
    );
  });

  testWidgets('red night keeps every block legible', (tester) async {
    await pumpPanel(
      tester,
      theme: SkotiqTheme.redNight,
      overrides: const [],
      child: SingleChildScrollView(
        child: Column(
          children: <Widget>[
            NightSchedulerSection(decision: _decision(), minScore: 30),
            const NightBroadcastSection(broadcast: _broadcast),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
