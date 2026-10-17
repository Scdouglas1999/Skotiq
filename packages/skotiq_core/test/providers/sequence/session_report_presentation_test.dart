// A modal Session Report + "How did this run go? / Write note" prompt after
// EVERY finished run is a modal per minute with the autopilot armed and its
// dispatched runs failing fast — appearing over whatever screen the operator is
// on (the Builder at 00:06:13, Plan Tonight at 00:06:53, History at 00:07:40)
// and each one swallowing the click aimed at the app underneath.
//
// A report the operator asked for by pressing Start is worth a modal. A report
// for a run the autopilot dispatched while nobody was watching is not — it gets
// queued, and the operator opens it when they come back.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_status.dart';
import 'package:skotiq_core/src/models/sequence/active_plan_owner.dart';
import 'package:skotiq_core/src/providers/sequence/session_report_presentation.dart';

void main() {
  group('sessionReportPresentationFor', () {
    test(
      'a hand-started run with the autopilot idle still opens the modal',
      () {
        expect(
          sessionReportPresentationFor(
            schedulerState: SchedulerState.idle,
            planOwner: ActivePlanOwner.manual,
          ),
          SessionReportPresentation.modal,
        );
      },
    );

    test('a run finishing while the autopilot is running is queued', () {
      expect(
        sessionReportPresentationFor(
          schedulerState: SchedulerState.running,
          planOwner: ActivePlanOwner.manual,
        ),
        SessionReportPresentation.queued,
      );
    });

    test("the autopilot's own dispatch is queued even after it disengages", () {
      // The engine stops on the way out of the night; the run that just ended
      // was still nobody's decision to watch.
      expect(
        sessionReportPresentationFor(
          schedulerState: SchedulerState.idle,
          planOwner: ActivePlanOwner.autopilot,
        ),
        SessionReportPresentation.queued,
      );
    });

    test('a paused autopilot still holds the rig, so reports stay queued', () {
      expect(
        sessionReportPresentationFor(
          schedulerState: SchedulerState.paused,
          planOwner: ActivePlanOwner.manual,
        ),
        SessionReportPresentation.queued,
      );
    });
  });

  group('pendingSessionReportsProvider', () {
    test('queued reports accumulate instead of stacking modals', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(pendingSessionReportsProvider.notifier);

      notifier.enqueue(
        PendingSessionReport(
          sessionId: 1,
          runId: 11,
          endedAt: DateTime(2026, 8, 14, 0, 6, 13),
        ),
      );
      notifier.enqueue(
        PendingSessionReport(
          sessionId: 2,
          runId: 12,
          endedAt: DateTime(2026, 8, 14, 0, 6, 53),
        ),
      );

      expect(container.read(pendingSessionReportsProvider), hasLength(2));
    });

    test('the same run is never queued twice', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(pendingSessionReportsProvider.notifier);
      final report = PendingSessionReport(
        sessionId: 1,
        runId: 11,
        endedAt: DateTime(2026, 8, 14, 0, 6, 13),
      );

      notifier.enqueue(report);
      notifier.enqueue(report);

      expect(container.read(pendingSessionReportsProvider), hasLength(1));
    });

    test('an unattended night cannot grow the queue without bound', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(pendingSessionReportsProvider.notifier);
      for (var i = 0; i < 500; i++) {
        notifier.enqueue(
          PendingSessionReport(
            sessionId: i,
            runId: i,
            endedAt: DateTime(2026, 8, 14).add(Duration(minutes: i)),
          ),
        );
      }

      final queue = container.read(pendingSessionReportsProvider);
      expect(queue, hasLength(PendingSessionReportsNotifier.maxRetained));
      // The newest survive — a report from eight hours ago is the one to drop.
      expect(queue.last.sessionId, 499);
    });

    test('opening a queued report removes it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(pendingSessionReportsProvider.notifier);
      final report = PendingSessionReport(
        sessionId: 7,
        runId: 70,
        endedAt: DateTime(2026, 8, 14),
      );
      notifier.enqueue(report);

      notifier.remove(report);

      expect(container.read(pendingSessionReportsProvider), isEmpty);
    });
  });
}
