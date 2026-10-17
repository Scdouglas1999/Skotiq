import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/providers/session_provider.dart';
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
      catalogId: 'M42',
      objectType: 'Nebula',
      ra: 5.6,
      dec: -5.4,
      positionAngle: null,
      magnitude: 4.0,
      constellation: 'Orion',
      sizeArcmin: 65.0,
      minAltitude: 30.0,
      priority: 8,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0.0,
      goalIntegrationSecs: 1200.0,
      filterProgress: null,
      notes: null,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      isFavorite: true,
    );

    db.ImagingSession makeSession(double integrationSecs) => db.ImagingSession(
      id: 11,
      name: 'M42',
      profileId: null,
      targetId: 1,
      startTime: DateTime.utc(2026, 1, 2, 2),
      endTime: DateTime.utc(2026, 1, 2, 4),
      totalExposures: 10,
      successfulExposures: 6,
      failedExposures: 0,
      totalIntegrationSecs: integrationSecs,
      avgTemperature: null,
      avgHumidity: null,
      avgSeeing: null,
      avgHfr: null,
      avgGuidingRms: null,
      autofocusCount: 0,
      notes: null,
      status: 'completed',
      sequenceId: null,
      equipmentSnapshot: null,
    );

    test('a session whose integration excludes rejected subs is not '
        'over-credited', () {
      // 6 accepted * 120s = 720s of real integration. Had the session counted
      // all 10 captures (incl. 4 rejects) the budget would have read 1200s and
      // shown the project as 100% complete. With accepted-only accounting it is
      // correctly 720/1200 = 0.6.
      final accepted = service.summarize(
        targets: [makeTarget()],
        sessions: [makeSession(720.0)],
      );
      expect(accepted.single.integratedSecs, 720.0);
      expect(accepted.single.completionFraction, closeTo(0.6, 1e-9));
      expect(accepted.single.isCompleted, isFalse);
      expect(accepted.single.remainingSecs, 480.0);
    });
  });
}
