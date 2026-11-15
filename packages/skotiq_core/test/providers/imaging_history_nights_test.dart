import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart'
    show
        allDbImagesProvider,
        allDbTargetsProvider,
        allSessionsProvider,
        imagingHistoryProvider,
        integrationGoalsStreamProvider,
        ImagingHistory,
        ImagingHistoryQuery;
import 'package:skotiq_core/src/database/database.dart' as db;

db.DbTarget _target(int id, String name) => db.DbTarget(
  id: id,
  name: name,
  ra: 6.08,
  dec: 50.0,
  minAltitude: 30.0,
  priority: 5,
  totalPlannedSubs: 0,
  capturedSubs: 0,
  totalIntegrationSecs: 0.0,
  goalIntegrationSecs: 0.0,
  createdAt: DateTime(2026, 11, 11),
  updatedAt: DateTime(2026, 11, 11),
  isFavorite: false,
);

/// A sequence run's session: it names the run, not a target.
db.ImagingSession _run(int id, DateTime start, double integrationSecs) =>
    db.ImagingSession(
      id: id,
      name: 'Stop and recover',
      profileId: 1,
      startTime: start,
      endTime: start.add(const Duration(seconds: 40)),
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: integrationSecs,
      autofocusCount: 0,
      status: 'completed',
    );

db.DbCapturedImage _light(int id, int sessionId, DateTime at) =>
    db.DbCapturedImage(
      id: id,
      filePath: '/captures/Field One_L_$id.fits',
      fileName: 'Field One_L_$id.fits',
      fileFormat: 'fits',
      sessionId: sessionId,
      targetId: 1,
      frameType: 'light',
      exposureDuration: 4,
      binX: 1,
      binY: 1,
      filter: 'L',
      isPlateSolved: false,
      capturedAt: at,
      createdAt: at,
      isAccepted: true,
    );

/// The Planetarium's imaging history counts nights the way Plan, Analytics
/// and the Darkroom do: two runs before and after midnight are one night, and
/// a run the next evening is a second one.
void main() {
  test(
    'the planetarium history counts observing nights, not sessions',
    () async {
      final evening = DateTime(2026, 11, 11, 22);
      final afterMidnight = DateTime(2026, 11, 12, 2);
      final nextEvening = DateTime(2026, 11, 12, 21);
      final container = ProviderContainer(
        overrides: [
          allDbTargetsProvider.overrideWith(
            (ref) => Stream.value([_target(1, 'Field One')]),
          ),
          allSessionsProvider.overrideWith(
            (ref) => Stream.value([
              _run(1, evening, 4),
              _run(2, afterMidnight, 4),
              _run(3, nextEvening, 4),
            ]),
          ),
          allDbImagesProvider.overrideWith(
            (ref) => Stream.value([
              _light(1, 1, evening),
              _light(2, 2, afterMidnight),
              _light(3, 3, nextEvening),
            ]),
          ),
          integrationGoalsStreamProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
      );
      addTearDown(container.dispose);
      const query = ImagingHistoryQuery(
        objectName: 'Field One',
        raHours: 6.08,
        decDegrees: 50.0,
      );
      final sub = container.listen(imagingHistoryProvider(query), (_, __) {});
      addTearDown(sub.close);

      ImagingHistory? history;
      for (var i = 0; i < 20 && history == null; i++) {
        await Future<void>.delayed(Duration.zero);
        history = container.read(imagingHistoryProvider(query)).valueOrNull;
      }
      expect(history, isNotNull);
      expect(history!.nightCount, 2);
      expect(history.totalIntegrationSecs, 12);
    },
  );
}
