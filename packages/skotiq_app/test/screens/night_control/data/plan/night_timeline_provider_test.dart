// The night strip: sunset to sunrise with one estimated window per target.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_timeline_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import 'plan_test_support.dart';

void main() {
  final evening = DateTime(2026, 10, 19, 18, 36);

  test('no site: no timeline', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      site: false,
    );
    addTearDown(container.dispose);

    expect(container.read(nightTimelineProvider), isNull);
  });

  test('no plan: the night alone', () {
    final container = planContainer(now: evening);
    addTearDown(container.dispose);

    final timeline = container.read(nightTimelineProvider)!;
    expect(timeline.sunset, DateTime(2026, 10, 19, 18, 18));
    expect(timeline.sunrise, DateTime(2026, 10, 20, 7, 10));
    expect(timeline.astroDark, DateTime(2026, 10, 19, 19, 48));
    expect(timeline.astroDawn, DateTime(2026, 10, 20, 5, 44));
    expect(timeline.now, evening);
    expect(timeline.windows, isEmpty);
  });

  test('two targets: two estimated windows, in plan order, back to back', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
    );
    addTearDown(container.dispose);

    final windows = container.read(nightTimelineProvider)!.windows;
    expect(windows.map((w) => w.name), ['M74', 'NGC 891']);
    expect(windows.every((w) => w.estimated), isTrue);
    expect(
      windows.every((w) => w.state == TimelineWindowState.planned),
      isTrue,
    );
    expect(windows[0].start, evening);
    expect(windows[0].end.isAfter(windows[0].start), isTrue);
    expect(windows[1].start, windows[0].end,
        reason: 'the next target starts where the first one ends');
    expect(windows[1].end.isAfter(windows[1].start), isTrue);
  });

  test('while running, windows keep the run start and mark progress', () {
    final sessionStart = DateTime(2026, 10, 19, 19, 50);
    final m74Started = DateTime(2026, 10, 19, 19, 51);
    final m74Ended = DateTime(2026, 10, 19, 19, 58);
    final container = planContainer(
      now: DateTime(2026, 10, 19, 20, 2),
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(isActive: true, startTime: sessionStart),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentTarget: 'NGC 891',
        nodeStatuses: {
          'm74': NodeStatus.success,
          'ngc891': NodeStatus.running,
        },
      ),
      events: [
        nodeEvent('m74', m74Started),
        nodeEvent('m74', m74Ended, completedStatus: 'success'),
      ],
    );
    addTearDown(container.dispose);

    final windows = container.read(nightTimelineProvider)!.windows;
    expect(windows[0].state, TimelineWindowState.done);
    expect(windows[0].start, m74Started);
    expect(windows[0].end, m74Ended);
    expect(windows[0].estimated, isFalse, reason: 'both ends recorded');
    expect(windows[1].state, TimelineWindowState.active);
    expect(windows[1].estimated, isTrue);
    expect(windows[1].start.isBefore(DateTime(2026, 10, 19, 20, 2)), isTrue,
        reason: 'anchored at the session start, not at now');
  });

  test('a run past midnight keeps the night it started in', () {
    final sessionStart = DateTime(2026, 10, 19, 23, 30);
    final now = DateTime(2026, 10, 20, 0, 40);
    final container = planContainer(
      now: now,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(isActive: true, startTime: sessionStart),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentTarget: 'M74',
        nodeStatuses: {'m74': NodeStatus.running},
      ),
    );
    addTearDown(container.dispose);

    final timeline = container.read(nightTimelineProvider)!;
    expect(timeline.now, now);
    expect(timeline.sunset.isBefore(now) && now.isBefore(timeline.sunrise),
        isTrue);
    expect(timeline.windows.first.start, sessionStart);
    expect(timeline.windows.first.state, TimelineWindowState.active);
    expect(timeline.windows.last.start.isAfter(sessionStart), isTrue);
  });
}
