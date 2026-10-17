// The DepthLock panel: a list that scans, a detail view that explains, five
// states that read differently, and actions pinned to the revision they were
// shown against.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'depthlock_test_doubles.dart';

Future<void> _pumpPanel(
  WidgetTester tester,
  FakeDepthLockBackend backend,
) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        depthLockBackendProvider.overrideWithValue(backend),
        depthLockEventStreamProvider.overrideWithValue(
          const Stream<SkotiqEvent>.empty(),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SizedBox(
            width: 380,
            child: DepthLockPanel(colors: SkotiqColors.dark),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDetail(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('five states read as five different things', (tester) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        for (final (index, state) in DepthLockState.values.indexed)
          depthLockGoalFixture(
            id: 'goal-$index',
            definition: depthLockDefinitionFixture(label: 'Region $index'),
            report: depthLockReportFixture(state: state),
          ),
      ],
    );
    await _pumpPanel(tester, backend);

    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('Measuring'), findsOneWidget);
    expect(find.text('Confirming'), findsOneWidget);
    expect(find.text('Achieved'), findsOneWidget);
    expect(find.text('Unreliable'), findsOneWidget);
  });

  testWidgets('a waiting goal counts its exposures towards the minimum', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          report: depthLockReportFixture(
            state: DepthLockState.insufficientEvidence,
            evidenceFrames: 11,
            score: null,
            conservativeScore: null,
          ),
        ),
      ],
    );
    await _pumpPanel(tester, backend);

    expect(find.text('11 of 32 exposures'), findsOneWidget);
    expect(find.text('before measuring starts'), findsOneWidget);
  });

  testWidgets('a measuring goal shows its depth against the goal', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          definition: depthLockDefinitionFixture(threshold: 6),
          report: depthLockReportFixture(
            state: DepthLockState.collecting,
            score: 4.9,
            conservativeScore: 3.9,
          ),
        ),
      ],
    );
    await _pumpPanel(tester, backend);

    expect(find.text('S/N 3.9'), findsOneWidget);
    expect(find.text('needs 6.0'), findsOneWidget);
    final bar = tester.widget<SkotiqProgressBar>(
      find.byType(SkotiqProgressBar),
    );
    expect(bar.value, closeTo(3.9 / 6.0, 1e-9));
  });

  testWidgets('a confirming goal names its confirmation window in detail', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          report: depthLockReportFixture(
            state: DepthLockState.confirmationPending,
            confirmationFrames: 12,
          ),
        ),
      ],
    );
    await _pumpPanel(tester, backend);
    // The list row stays to one line; the window is part of the detail.
    expect(find.text('12 of 16 confirming exposures'), findsNothing);

    await _openDetail(tester, 'Tidal tail');
    expect(find.text('12 of 16 confirming exposures'), findsOneWidget);
  });

  testWidgets('tapping a goal opens its detail and Back returns to the list', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          definition: depthLockDefinitionFixture(label: 'Tidal tail'),
          report: depthLockReportFixture(),
        ),
        depthLockGoalFixture(
          id: 'goal-2',
          definition: depthLockDefinitionFixture(label: 'Outer shell'),
          report: depthLockReportFixture(),
        ),
      ],
    );
    await _pumpPanel(tester, backend);

    // The list shows both and no per-goal actions.
    expect(find.text('Outer shell'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Re-measure'), findsNothing);

    await _openDetail(tester, 'Outer shell');
    expect(find.text('Tidal tail'), findsNothing);
    expect(find.widgetWithText(SkotiqButton, 'Re-measure'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Edit region'), findsOneWidget);

    await tester.tap(find.widgetWithText(SkotiqButton, 'All goals'));
    await tester.pumpAndSettle();
    expect(find.text('Tidal tail'), findsOneWidget);
    expect(find.text('Outer shell'), findsOneWidget);
  });

  testWidgets('the detail labels every number with what it is', (tester) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          report: depthLockReportFixture(
            score: 6.4,
            conservativeScore: 5.2,
            uncertaintyAdu: 0.31,
            // 15 of 16: a 120 x 120 arcsec region at 30 arcsec is a 4 x 4 grid.
            coverage: 0.9375,
            evidenceFrames: 48,
            confirmationFrames: 18,
          ),
          definition: depthLockDefinitionFixture(scaleArcsec: 30),
        ),
      ],
    );
    await _pumpPanel(tester, backend);
    await _openDetail(tester, 'Tidal tail');

    expect(find.text('6.4'), findsOneWidget);
    expect(find.text('5.2'), findsOneWidget);
    expect(find.text('CONSERVATIVE'), findsOneWidget);
    expect(find.text('0.31 ADU'), findsOneWidget);
    expect(find.text('15 of 16 apertures'), findsOneWidget);
    expect(find.text('48'), findsOneWidget);
    expect(find.text('EVIDENCE'), findsOneWidget);
    expect(find.text('2026-09-01 21:40'), findsOneWidget);
  });

  testWidgets('the newest frame\'s refusal is repeated verbatim', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          report: depthLockReportFixture(),
          analysisCurrent: false,
          lastIssue: 'CCD-TEMP -4.2 differs from the goal by more than 1.0 C',
        ),
      ],
    );
    await _pumpPanel(tester, backend);
    // The list row carries it as its one-line status…
    expect(
      find.textContaining(
        'CCD-TEMP -4.2 differs from the goal by more than 1.0 C',
      ),
      findsOneWidget,
    );

    // …and the detail repeats it in full beside the analysis note.
    await _openDetail(tester, 'Tidal tail');
    expect(
      find.textContaining(
        'CCD-TEMP -4.2 differs from the goal by more than 1.0 C',
      ),
      findsOneWidget,
    );
    expect(find.text('Analysis pending for the latest frame.'), findsOneWidget);
  });

  testWidgets('the automatic-completion switch writes at the shown revision', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(revision: 7, report: depthLockReportFixture()),
      ],
    );
    await _pumpPanel(tester, backend);
    await _openDetail(tester, 'Tidal tail');

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(SkotiqSwitchRow, 'Automatic completion'),
        matching: find.byType(SkotiqSwitch),
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.preferences?.goalId, 'goal-1');
    expect(backend.preferences?.revision, 7);
    expect(backend.preferences?.automatic, isTrue);
    expect(backend.preferences?.enabled, isTrue);
  });

  testWidgets('re-measure replays the goal it was pressed on', (tester) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(id: 'goal-9', report: depthLockReportFixture()),
      ],
    );
    await _pumpPanel(tester, backend);
    await _openDetail(tester, 'Tidal tail');

    await tester.tap(find.widgetWithText(SkotiqButton, 'Re-measure'));
    await tester.pumpAndSettle();

    expect(backend.replayed, 'goal-9');
  });

  testWidgets('the empty state offers the tool, disabled while it is', (
    tester,
  ) async {
    await _pumpPanel(tester, FakeDepthLockBackend());

    expect(find.text('No depth goals'), findsOneWidget);
    expect(
      find.textContaining('Mark a faint region on a solved sub'),
      findsOneWidget,
    );
    // Two offers of the same action — the card's and the empty state's — and
    // both are dead while no frame can anchor a region.
    for (final button in tester.widgetList<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Mark a region'),
    )) {
      expect(button.onPressed, isNull);
    }
    expect(
      find.textContaining('No frame is on screen'),
      findsOneWidget,
    );
  });

  testWidgets('the footnote says what happens when an ordinary limit wins', (
    tester,
  ) async {
    await _pumpPanel(tester, FakeDepthLockBackend());

    expect(
      find.textContaining(
        'If the plan\'s count, time or visibility limit arrives first, the run '
        'ends as authored and the goal stays open for the next session.',
      ),
      findsOneWidget,
    );
  });
}
