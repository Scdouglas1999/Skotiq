import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/services/project_tracking_service.dart';

db.DbTarget _target(int id, String name) => db.DbTarget(
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

db.DbCapturedImage _frame(
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
  return db.DbCapturedImage(
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

  // Owner rule: a goal set in the old Analytics hours dialog must not start
  // reading "Not set" once goals moved to per-filter integration goals.
  test('a target with only the old hours goal keeps it as a goal over all '
      'filters', () {
    final legacy = _target(1, 'M101').copyWith(goalIntegrationSecs: 36000);
    final progress = service
        .summarize(
          targets: [legacy],
          sessions: const [],
          frames: [
            _frame(1, sessionId: 11, filter: 'L'),
            _frame(2, sessionId: 11, filter: 'R'),
          ],
          goals: const [],
        )
        .single;
    expect(progress.isTracked, isTrue);
    expect(progress.goal.allFilters, isTrue);
    expect(progress.goalIntegrationSecs, 36000);
    expect(progress.remainingSecs, 36000 - 600);

    final withFilterGoal = service
        .summarize(
          targets: [legacy],
          sessions: const [],
          frames: const [],
          goals: [_goal('L', 300, 10)],
        )
        .single;
    expect(withFilterGoal.goal.allFilters, isFalse);
    expect(withFilterGoal.goalIntegrationSecs, 3000);
  });

  test('two goals in one filter share that filter\'s time instead of each '
      'counting all of it', () {
    final goals = [
      _goal('Ha', 300, 10),
      _goal('ha', 600, 10),
      _goal('L', 300, 4),
    ];
    final frames = [
      for (var i = 1; i <= 15; i++) _frame(i, filter: 'Ha', exposure: 300),
      _frame(20, filter: 'L', exposure: 300),
    ];

    final progress = service
        .summarize(
          targets: [_target(1, 'NGC 7000')],
          sessions: const [],
          frames: frames,
          goals: goals,
        )
        .single;
    expect(progress.goalIntegrationSecs, 3000 + 6000 + 1200);
    expect(progress.goal.doneSecs, 4500 + 300);
    expect(progress.goal.isComplete, isFalse);

    final perGoal = acceptedPerGoal(acceptedLightsByFilter(frames), goals);
    expect(perGoal.map((g) => g.seconds), [3000, 1500, 300]);
    expect(perGoal.map((g) => g.frames), [10, 5, 1]);
  });

  test('time beyond a filter\'s goals stays on its last goal', () {
    final goals = [_goal('Ha', 300, 2), _goal('Ha', 600, 1)];
    final frames = [
      for (var i = 1; i <= 6; i++) _frame(i, filter: 'Ha', exposure: 300),
    ];
    final perGoal = acceptedPerGoal(acceptedLightsByFilter(frames), goals);
    expect(perGoal.map((g) => g.seconds), [600, 1200]);
    expect(perGoal.map((g) => g.frames), [2, 4]);
  });

  test('a goal counts the frames filed under the wheel\'s longer name for '
      'its filter, and a closer spelling hides a looser one', () {
    final frames = [
      for (var i = 1; i <= 4; i++) _frame(i, filter: 'Ha 7nm', exposure: 300),
      for (var i = 5; i <= 6; i++) _frame(i, filter: 'L', exposure: 300),
      for (var i = 7; i <= 9; i++)
        _frame(i, filter: 'L-eXtreme', exposure: 300),
    ];
    final accepted = acceptedLightsByFilter(frames);
    expect(acceptedInGoalFilter(accepted, 'Ha').frames, 4);
    expect(acceptedInGoalFilter(accepted, 'H-alpha').seconds, 1200);
    expect(acceptedInGoalFilter(accepted, 'L').frames, 2);
    expect(acceptedInGoalFilter(accepted, 'OIII').frames, 0);
    final perGoal = acceptedPerGoal(accepted, [
      _goal('Ha', 300, 2),
      _goal('H-alpha', 300, 10),
    ]);
    expect(perGoal.map((g) => g.frames), [2, 2]);
  });
}
