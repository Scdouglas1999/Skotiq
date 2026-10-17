import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/services/project_tracking_service.dart';

void main() {
  group('ProjectTrackingService', () {
    const service = ProjectTrackingService();

    test('aggregates multi-night integration against goals', () {
      final targets = <db.Target>[
        db.Target(
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
          goalIntegrationSecs: 14400.0,
          filterProgress: null,
          notes: null,
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
          isFavorite: true,
        ),
      ];

      final sessions = <db.ImagingSession>[
        db.ImagingSession(
          id: 11,
          name: 'M42 - night 1',
          profileId: null,
          targetId: 1,
          startTime: DateTime.utc(2026, 1, 2, 2),
          endTime: DateTime.utc(2026, 1, 2, 4),
          totalExposures: 24,
          successfulExposures: 20,
          failedExposures: 4,
          totalIntegrationSecs: 5400.0,
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
        ),
        db.ImagingSession(
          id: 12,
          name: 'M42 - night 2',
          profileId: null,
          targetId: 1,
          startTime: DateTime.utc(2026, 1, 3, 2),
          endTime: DateTime.utc(2026, 1, 3, 5),
          totalExposures: 18,
          successfulExposures: 15,
          failedExposures: 3,
          totalIntegrationSecs: 7200.0,
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
        ),
      ];

      final progress = service
          .summarize(targets: targets, sessions: sessions)
          .single;

      expect(progress.sessionCount, 2);
      expect(progress.successfulExposures, 35);
      expect(progress.integratedSecs, 12600.0);
      expect(progress.remainingSecs, 1800.0);
      expect(progress.completionFraction, closeTo(0.875, 1e-6));
      expect(progress.isTracked, isTrue);
    });
  });
}
