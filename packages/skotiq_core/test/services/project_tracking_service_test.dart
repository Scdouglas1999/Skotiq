import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/services/project_tracking_service.dart';

db.Target _target(int id, String name) => db.Target(
  id: id,
  name: name,
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
  isFavorite: false,
);

db.CapturedImage _frame(
  int id, {
  int? targetId = 1,
  int? sessionId,
  String frameType = 'light',
  String? filter,
  double exposure = 300,
  bool accepted = true,
  DateTime? at,
}) {
  final when = at ?? DateTime.utc(2026, 1, 2, 2, id);
  return db.CapturedImage(
    id: id,
    filePath: '/captures/$id.fits',
    fileName: '$id.fits',
    fileFormat: 'fits',
    sessionId: sessionId,
    targetId: targetId,
    frameType: frameType,
    exposureDuration: exposure,
    binX: 1,
    binY: 1,
    filter: filter,
    isPlateSolved: false,
    capturedAt: when,
    createdAt: when,
    isAccepted: accepted,
  );
}

db.ImagingSession _session(int id, {int? targetId}) => db.ImagingSession(
  id: id,
  name: 'Night $id',
  targetId: targetId,
  startTime: DateTime.utc(2026, 1, id),
  totalExposures: 0,
  successfulExposures: 0,
  failedExposures: 0,
  totalIntegrationSecs: 0,
  autofocusCount: 0,
  status: 'completed',
);

IntegrationGoal _goal(String filter, double exposure, int frames) =>
    IntegrationGoal(
      targetId: 1,
      filter: filter,
      exposureSeconds: exposure,
      frameCount: frames,
      createdAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  const service = ProjectTrackingService();

  test('integration, frames and filters come from the accepted lights', () {
    final progress = service
        .summarize(
          targets: [_target(1, 'M42')],
          sessions: const [],
          frames: [
            _frame(1, sessionId: 11, filter: 'Ha'),
            _frame(2, sessionId: 11, filter: 'ha'),
            _frame(3, sessionId: 12, filter: 'OIII'),
            _frame(4, sessionId: 12, filter: 'Ha', accepted: false),
            _frame(5, sessionId: 12, frameType: 'dark'),
            _frame(6, targetId: 2, sessionId: 12, filter: 'Ha'),
          ],
          goals: [_goal('Ha', 300, 20), _goal('OIII', 300, 20)],
        )
        .single;

    expect(progress.acceptedFrames, 3);
    expect(progress.integratedSecs, 900);
    expect(
      [for (final f in progress.filters) '${f.filter} ${f.frames}'],
      ['Ha 2', 'OIII 1'],
    );
    expect(progress.goalIntegrationSecs, 12000);
    expect(progress.completionFraction, closeTo(0.075, 1e-9));
    expect(progress.lastImagedAt, DateTime.utc(2026, 1, 2, 2, 4));
  });

  test('sessions are the ones holding the target\'s lights, plus any that '
      'name it', () {
    final progress = service
        .summarize(
          targets: [_target(1, 'M42')],
          sessions: [
            _session(11),
            _session(12),
            _session(13, targetId: 1),
            _session(14),
          ],
          frames: [
            _frame(1, sessionId: 11),
            _frame(2, sessionId: 12, accepted: false),
            _frame(3, targetId: 2, sessionId: 14),
          ],
          goals: const [],
        )
        .single;

    expect(progress.sessionCount, 3);
    expect(progress.isTracked, isFalse);
  });

  test('a target with no frames and no goal is listed with nothing', () {
    final progress = service
        .summarize(
          targets: [_target(1, 'M42')],
          sessions: const [],
          frames: const [],
          goals: const [],
        )
        .single;
    expect(progress.sessionCount, 0);
    expect(progress.integratedSecs, 0);
    expect(progress.filters, isEmpty);
    expect(progress.lastImagedAt, isNull);
  });
}
