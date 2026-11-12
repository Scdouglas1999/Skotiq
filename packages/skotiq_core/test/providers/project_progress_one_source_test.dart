import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart' show IntegrationGoal;
import 'package:skotiq_core/providers.dart'
    show allDbImagesProvider, allDbTargetsProvider, allSessionsProvider, integrationGoalsStreamProvider, projectProgressListProvider;
import 'package:skotiq_core/services.dart' show ProjectProgress;
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

db.DbCapturedImage _light(int id, int sessionId, DateTime at) => db.DbCapturedImage(
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

/// UX walk 2, F35: Analytics > Projects showed Field One with 0 s, 0 frames
/// and 0 sessions while History listed its two sessions and the Darkroom its
/// 11 frames (44 s), and showed "Goal: Not set" for M33 whose L goal was set
/// in Plan > Projects. The card reads the frames and the goals, as every other
/// view does.
void main() {
  test('a target imaged by sequence runs shows its sessions, frames and the '
      'goal set in Plan', () async {
    final night = DateTime(2026, 11, 11, 8, 21);
    final frames = [
      for (var i = 0; i < 3; i++)
        _light(i + 1, 1, night.add(Duration(seconds: 5 * i))),
      for (var i = 0; i < 8; i++)
        _light(i + 4, 2, night.add(Duration(seconds: 30 + 5 * i))),
    ];
    final container = ProviderContainer(
      overrides: [
        allDbTargetsProvider.overrideWith(
          (ref) => Stream.value([_target(1, 'Field One'), _target(2, 'M33')]),
        ),
        allSessionsProvider.overrideWith(
          (ref) => Stream.value([
            _run(1, night, 12),
            _run(2, night.add(const Duration(seconds: 29)), 32),
          ]),
        ),
        allDbImagesProvider.overrideWith((ref) => Stream.value(frames)),
        integrationGoalsStreamProvider.overrideWith(
          (ref) => Stream.value([
            IntegrationGoal(
              id: 1,
              targetId: 2,
              filter: 'L',
              exposureSeconds: 105,
              frameCount: 20,
              createdAt: DateTime.utc(2026, 11, 11),
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(projectProgressListProvider, (_, __) {});
    addTearDown(sub.close);

    List<ProjectProgress>? progress;
    for (var i = 0; i < 20 && progress == null; i++) {
      await Future<void>.delayed(Duration.zero);
      progress = container.read(projectProgressListProvider).valueOrNull;
    }
    expect(progress, isNotNull);
    final fieldOne = progress!.singleWhere((p) => p.target.name == 'Field One');
    final m33 = progress.singleWhere((p) => p.target.name == 'M33');

    expect(fieldOne.sessionCount, 2);
    expect(fieldOne.integratedSecs, 44);
    expect(fieldOne.isTracked, isFalse);
    expect(m33.isTracked, isTrue);
    expect(m33.goalIntegrationSecs, 20 * 105);
    expect(m33.integratedSecs, 0);
  });
}
