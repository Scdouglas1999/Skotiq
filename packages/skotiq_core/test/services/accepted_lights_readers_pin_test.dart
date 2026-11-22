// Accepted light frames per filter, as each reader counts them for the same
// frames: target progress from the host's image list and from the database,
// the scheduler's per-goal count, and the project page's filter rows.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/models/scheduler/target_progress.dart';
import 'package:skotiq_core/src/services/project_tracking_service.dart';
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart';
import 'package:skotiq_core/src/services/scheduler/target_progress_service.dart';

/// (filter, frame type, accepted, exposure seconds, how many)
const _frames = <(String?, String, bool, double, int)>[
  (null, 'light', true, 60, 1),
  ('', 'light', true, 60, 1),
  (' ', 'light', true, 60, 1),
  ('L', 'light', true, 60, 2),
  ('l', 'light', true, 60, 1),
  ('Ha', 'light', true, 300, 1),
  ('Ha 7nm', 'light', true, 300, 2),
  ('Unfiltered', 'light', true, 30, 1),
  ('R', 'light', false, 60, 1),
  ('R', 'dark', true, 60, 1),
  ('R', 'Light', true, 60, 1),
  ('R', 'light', true, 60, 1),
];

const _goalFilters = ['', 'L', 'Ha', 'R', 'Unfiltered', 'OIII'];

void main() {
  late SkotiqDatabase database;
  late IntegrationGoalService goals;
  late TargetProgressService progress;
  late int targetId;
  late List<DbCapturedImage> rows;

  setUp(() async {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    goals = IntegrationGoalService(database);
    progress = TargetProgressService(
      database: database,
      goalService: goals,
      clock: () => DateTime(2026, 5, 12, 10),
    );
    targetId = await database
        .into(database.targets)
        .insert(TargetsCompanion.insert(name: 'M31', ra: 0.7, dec: 41.3));
    var n = 0;
    for (final (filter, type, accepted, secs, count) in _frames) {
      for (var i = 0; i < count; i++) {
        n++;
        await database
            .into(database.capturedImages)
            .insert(
              CapturedImagesCompanion.insert(
                filePath: 'f$n.fits',
                fileName: 'f$n.fits',
                exposureDuration: secs,
                capturedAt: DateTime(2026, 5, 11, 23, n),
                frameType: Value(type),
                targetId: Value(targetId),
                filter: Value(filter),
                isAccepted: Value(accepted),
              ),
            );
      }
    }
    for (var i = 0; i < _goalFilters.length; i++) {
      await goals.upsert(
        IntegrationGoal(
          targetId: targetId,
          filter: _goalFilters[i],
          exposureSeconds: 60,
          frameCount: 10,
          priority: i,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
    }
    rows = await database.select(database.capturedImages).get();
  });

  tearDown(() => database.close());

  test('target progress counts the same frames from the list and the '
      'database, per goal', () async {
    String perGoal(TargetProgress p) => [
      for (final f in p.perFilter) '${f.filter}=${f.capturedFrames}',
    ].join(' ');
    final fromList = await progress.forTarget(
      targetId: targetId,
      targetName: 'M31',
      capturedImages: rows,
    );
    final fromDb = await progress.forTarget(
      targetId: targetId,
      targetName: 'M31',
    );
    const expected = 'OIII=0 Unfiltered=1 R=1 Ha=3 L=3 =3';
    expect(perGoal(fromList), expected);
    expect(perGoal(fromDb), expected);
    expect(fromList.lastImagedAt, fromDb.lastImagedAt);
    expect(fromList.avgFramesPerNight, fromDb.avgFramesPerNight);
  });

  test('the scheduler counts a goal the same way', () async {
    expect(
      [
        for (final f in _goalFilters)
          await goals.capturedFrameCount(targetId: targetId, filter: f),
      ],
      [3, 3, 3, 1, 1, 0],
    );
  });

  test('the project page groups filters by case, and counts a goal as the '
      'scheduler does', () {
    final accepted = acceptedLightsByFilter(rows);
    expect(
      [
        for (final f in accepted)
          '${f.filter}:${f.frames}:${f.seconds}${f.noFilter ? ' (none)' : ''}',
      ],
      [
        'Ha:1:300.0',
        'Ha 7nm:2:600.0',
        'L:3:180.0',
        'R:1:60.0',
        // Frames filed blank (null, '' and ' ') are no filter; a frame filed
        // "Unfiltered" is a filter of that name, as the scheduler reads it.
        'Unfiltered:3:180.0 (none)',
        'Unfiltered:1:30.0',
      ],
    );
    expect(
      [for (final f in _goalFilters) acceptedInGoalFilter(accepted, f).frames],
      [
        for (final f in _goalFilters)
          goalFrameCount(
            f,
            {
              for (final (filter, type, ok, _, _) in _frames)
                if (ok && type == 'light') filter ?? '': 0,
            }..updateAll((key, _) => _countFiled(key)),
          ),
      ],
    );
    expect(
      [for (final f in _goalFilters) acceptedInGoalFilter(accepted, f).frames],
      [3, 3, 3, 1, 1, 0],
    );
  });
}

/// Accepted lights filed exactly as [filed] ('' for none).
int _countFiled(String filed) => [
  for (final (filter, type, ok, _, n) in _frames)
    if (ok && type == 'light' && (filter ?? '') == filed) n,
].fold(0, (a, b) => a + b);
