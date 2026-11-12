import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/providers/session_provider.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/services/project_tracking_service.dart';

/// Pins the multi-night integration-budget accounting:
///
///  * [SessionStateNotifier.recordExposureComplete] only advances the accepted
///    integration time ([SessionState.totalIntegrationSecs]) for ACCEPTED
///    frames. A rejected frame (auto-graded out for quality) is wasted sky
///    time, not progress, so it must not move the budget.
///  * [ProjectTrackingService] sums that same accepted integration into the
///    per-target completion fraction, so an auto-rejected sub must never push
///    a project closer to "done".
void main() {
  group('recordExposureComplete accept/reject accounting', () {
    late ProviderContainer container;
    late SessionStateNotifier notifier;

    setUp(() {
      container = ProviderContainer();
      // No session is started, so dbSessionId stays null and the internal
      // `_updateSessionServiceStats` call short-circuits before touching any
      // service/DB — we are exercising the pure in-memory accounting here.
      notifier = container.read(sessionStateProvider.notifier);
    });

    tearDown(() => container.dispose());

    test('an accepted frame advances the integration budget', () {
      notifier.recordExposureComplete(exposureTime: 60, hfr: 2.0);
      final s = container.read(sessionStateProvider);
      expect(s.completedExposures, 1);
      expect(s.rejectedExposures, 0);
      expect(s.totalIntegrationSecs, 60.0);
      expect(s.avgHfr, 2.0);
    });

    test('a rejected frame does NOT advance the integration budget', () {
      notifier.recordExposureComplete(exposureTime: 60, hfr: 2.0);
      notifier.recordExposureComplete(
        exposureTime: 60,
        hfr: 9.0,
        accepted: false,
      );

      final s = container.read(sessionStateProvider);
      // The capture itself completed, so the completed count includes it...
      expect(s.completedExposures, 2);
      // ...but it is tallied as a rejection and does NOT add sky time.
      expect(s.rejectedExposures, 1);
      expect(
        s.totalIntegrationSecs,
        60.0,
        reason: 'rejected frame must not add integration time',
      );
      // The bloated HFR of the rejected frame must not pollute the average.
      expect(s.avgHfr, 2.0);
    });

    test('mixed run: only accepted frames sum into integration', () {
      // accept, reject, accept, reject, accept
      notifier.recordExposureComplete(exposureTime: 120, hfr: 2.0);
      notifier.recordExposureComplete(
        exposureTime: 120,
        hfr: 8.0,
        accepted: false,
      );
      notifier.recordExposureComplete(exposureTime: 120, hfr: 2.2);
      notifier.recordExposureComplete(
        exposureTime: 120,
        hfr: 7.5,
        accepted: false,
      );
      notifier.recordExposureComplete(exposureTime: 120, hfr: 2.4);

      final s = container.read(sessionStateProvider);
      expect(s.completedExposures, 5);
      expect(s.rejectedExposures, 2);
      // 3 accepted * 120s = 360s, not 5 * 120 = 600s.
      expect(s.totalIntegrationSecs, 360.0);
      // Average over the 3 accepted HFRs only: (2.0 + 2.2 + 2.4) / 3 = 2.2.
      expect(s.avgHfr, closeTo(2.2, 1e-9));
    });
  });

  group('ProjectTrackingService budget reflects accepted-only integration', () {
    const service = ProjectTrackingService();

    db.Target makeTarget() => db.Target(
      id: 1,
      name: 'M42',
      ra: 5.6,
      dec: -5.4,
      minAltitude: 30.0,
      priority: 8,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0.0,
      goalIntegrationSecs: 0.0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      isFavorite: true,
    );

    db.CapturedImage makeLight(int id, {required bool accepted}) =>
        db.CapturedImage(
          id: id,
          filePath: '/captures/M42_$id.fits',
          fileName: 'M42_$id.fits',
          fileFormat: 'fits',
          sessionId: 11,
          targetId: 1,
          frameType: 'light',
          exposureDuration: 120,
          binX: 1,
          binY: 1,
          filter: 'Ha',
          isPlateSolved: false,
          capturedAt: DateTime.utc(2026, 1, 2, 2, id),
          createdAt: DateTime.utc(2026, 1, 2, 2, id),
          isAccepted: accepted,
        );

    test('rejected subs do not advance the goal', () {
      // 6 accepted * 120 s = 720 s of real integration. Counting all 10
      // captures (incl. 4 rejects) would read 1200 s and show the project as
      // complete; accepted-only it is 720/1200 = 0.6.
      final progress = service
          .summarize(
            targets: [makeTarget()],
            sessions: const [],
            frames: [
              for (var i = 0; i < 10; i++) makeLight(i, accepted: i < 6),
            ],
            goals: [
              IntegrationGoal(
                targetId: 1,
                filter: 'Ha',
                exposureSeconds: 120,
                frameCount: 10,
                createdAt: DateTime.utc(2026, 1, 1),
              ),
            ],
          )
          .single;
      expect(progress.integratedSecs, 720.0);
      expect(progress.acceptedFrames, 6);
      expect(progress.sessionCount, 1);
      expect(progress.completionFraction, closeTo(0.6, 1e-9));
      expect(progress.isCompleted, isFalse);
      expect(progress.remainingSecs, 480.0);
    });
  });
}
