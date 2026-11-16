// Which Darkroom targets are projects, how lights are grouped into targets,
// and the corrections a user can make, against a database shaped like the
// owner's: a real run target, a two-frame snapshot target, a calibration-only
// target, lights with no target, and one object saved under two names.
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

/// Records what it was asked to remove instead of removing anything.
class _Trash implements FileTrash {
  @override
  bool get restorable => true;
  final removed = <String>[];

  @override
  Future<List<String>> remove(List<String> paths) async {
    removed.addAll(paths);
    return const [];
  }
}

class _Owner {
  _Owner(this.db);
  final SkotiqDatabase db;
  late int ngc891, snap, calib, m1, crab, m101;
}

final _crabIdentity = CatalogIdentity<String>([
  (object: 'NGC1952', designations: ['NGC1952', 'M1']),
  (object: 'NGC891', designations: ['NGC891']),
]);

Future<_Owner> _seed() async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final owner = _Owner(db);
  Future<int> target(String name, double ra, double dec, {String? catalog}) =>
      db.targetsDao.createTarget(
        TargetsCompanion.insert(
          name: name,
          ra: ra,
          dec: dec,
          catalogId: Value(catalog),
        ),
      );
  owner.ngc891 = await target('NGC0891', 2.3759, 42.349);
  owner.snap = await target('NGC 7331', 22.616, 34.42);
  owner.calib = await target('Flat panel', 0, 0);
  owner.m1 = await target('M1', 5.575, 22.01);
  owner.crab = await target('NGC1952', 5.575, 22.01, catalog: 'NGC1952');
  owner.m101 = await target('M101', 14.053, 54.35);

  var n = 0;
  final start = DateTime(2026, 11, 1, 21);
  Future<int> light({
    int? targetId,
    String? run,
    String type = 'light',
    double exposure = 300,
    bool kept = true,
    double? solvedRa,
    double? solvedDec,
  }) {
    n++;
    return db
        .into(db.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: '/data/f_$n.fits',
            fileName: 'f_$n.fits',
            exposureDuration: exposure,
            capturedAt: start.add(Duration(minutes: 5 * n)),
            targetId: Value(targetId),
            frameType: Value(type),
            filter: const Value('L'),
            isAccepted: Value(kept),
            producingRunId: Value(run),
            isPlateSolved: Value(solvedRa != null),
            solvedRa: Value(solvedRa),
            solvedDec: Value(solvedDec),
          ),
        );
  }

  // A real project: a run's 20 kept 300 s subs (100 min) of NGC 891, plus one
  // of the run's lights that lost its target.
  for (var i = 0; i < 20; i++) {
    await light(targetId: owner.ngc891, run: 'run-891');
  }
  await light(run: 'run-891');
  // Two snapshots taken by hand.
  await light(targetId: owner.snap, exposure: 2);
  await light(targetId: owner.snap, exposure: 2);
  // Calibration only.
  for (var i = 0; i < 3; i++) {
    await light(targetId: owner.calib, type: 'dark');
  }
  // One object under two names, each from its own run.
  for (var i = 0; i < 4; i++) {
    await light(targetId: owner.m1, run: 'run-m1');
  }
  for (var i = 0; i < 4; i++) {
    await light(targetId: owner.crab, run: 'run-crab');
  }
  // Snapshots with no target: one solved on M101 (no run imaged it), one
  // solved on NGC 891 (a run's target), one not solved at all.
  await light(exposure: 1, solvedRa: 14.053, solvedDec: 54.36);
  await light(exposure: 1, solvedRa: 2.376, solvedDec: 42.35);
  await light(exposure: 1);
  return owner;
}

Future<DarkroomTargetFrames> _group(SkotiqDatabase db) => loadDarkroomTargets(
  db,
  readHeader: (_) async => FrameHeader(const {}),
  identity: _crabIdentity,
);

TargetCaptures _captures(List<DbCapturedImage> frames) {
  final kept = frames.where((f) => f.isAccepted).toList();
  return TargetCaptures(
    frames: frames.length,
    lights: frames.where((f) => f.frameType == 'light').length,
    keptLights: kept.length,
    keptSeconds: kept.fold(0, (s, f) => s + f.exposureDuration),
    runLights: frames.where((f) => f.producingRunId != null).length,
  );
}

Future<int> _count(SkotiqDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

DarkroomTargetGroup _groupOf(
  DarkroomTargetFrames grouped,
  String key,
  List<DbTarget> rows,
) => DarkroomTargetGroup(
  key: key,
  frames: grouped[key]!,
  row: rows.where((r) => r.name == key).firstOrNull,
);

void main() {
  group('the project rule', () {
    const rule = ProjectRule();

    test('a run with enough kept light is a project', () {
      expect(
        targetStanding(
          const TargetCaptures(
            frames: 20,
            lights: 20,
            keptLights: 20,
            keptSeconds: 6000,
            runLights: 20,
          ),
          rule,
        ),
        TargetStanding.project,
      );
    });

    test('two snapshots, a handful of subs, or calibration are not', () {
      const snapshots = TargetCaptures(
        frames: 2,
        lights: 2,
        keptLights: 2,
        keptSeconds: 4,
      );
      const handful = TargetCaptures(
        frames: 4,
        lights: 4,
        keptLights: 4,
        keptSeconds: 3600,
        runLights: 4,
      );
      const calibration = TargetCaptures(frames: 3);
      const rejected = TargetCaptures(frames: 12, lights: 12, runLights: 12);
      for (final c in [snapshots, handful, calibration, rejected]) {
        expect(targetStanding(c, rule), TargetStanding.capture);
      }
      expect(captureReason(snapshots, rule), 'Snapshots taken by hand');
      expect(captureReason(handful, rule), 'Fewer than 10 kept lights');
      expect(captureReason(calibration, rule), 'Calibration frames only');
      expect(captureReason(rejected, rule), 'No kept lights');
    });

    test('a target with nothing captured is unused', () {
      expect(
        targetStanding(const TargetCaptures(), rule),
        TargetStanding.unused,
      );
    });

    test('the minimums are the user\'s settings', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      expect(await ProjectRule.load(db.settingsDao), const ProjectRule());
      const short = ProjectRule(minKeptMinutes: 5, minKeptFrames: 2);
      await short.save(db.settingsDao);
      final loaded = await ProjectRule.load(db.settingsDao);
      expect(loaded, short);
      const twoSnapshots = TargetCaptures(
        frames: 2,
        lights: 2,
        keptLights: 2,
        keptSeconds: 600,
      );
      expect(targetStanding(twoSnapshots, loaded), TargetStanding.project);
    });

    test('the user\'s placement wins over the rule, either way', () {
      const project = TargetCaptures(
        frames: 20,
        lights: 20,
        keptLights: 20,
        keptSeconds: 6000,
      );
      const small = TargetCaptures(frames: 2, lights: 2, keptLights: 2);
      expect(
        targetStanding(project, rule, placement: TargetPlacement.hidden),
        TargetStanding.capture,
      );
      expect(
        captureReason(project, rule, placement: TargetPlacement.hidden),
        'Hidden by you',
      );
      expect(
        targetStanding(small, rule, placement: TargetPlacement.project),
        TargetStanding.project,
      );
    });
  });

  group('grouping lights into targets', () {
    late _Owner owner;
    setUp(() async => owner = await _seed());
    tearDown(() => owner.db.close());

    test('every rule, in order, on the owner-shaped database', () async {
      final grouped = await _group(owner.db);

      expect(grouped.byTarget.keys.toSet(), {
        'NGC0891',
        'NGC 7331',
        'M1',
        'M101',
        darkroomNoTargetKey,
      });
      // The run's stray light joins the run's one target.
      expect(grouped['NGC0891']!.length, 21);
      // Calibration frames are not lights.
      expect(grouped['Flat panel'], isNull);
      // One object under two names is one group, under the older name.
      expect(grouped['M1']!.length, 8);
      expect(grouped['NGC1952'], isNull);
      // A snapshot solved on a target no run imaged joins it.
      expect(grouped['M101']!.length, 1);
      // A snapshot solved on a run's target stays out of its masters, and an
      // unsolved one names nothing.
      expect(grouped[darkroomNoTargetKey]!.length, 2);
      expect(grouped.unidentified, {darkroomNoTargetKey});
    });

    test('the standing of each group', () async {
      final grouped = await _group(owner.db);
      const rule = ProjectRule();
      TargetStanding of(String key) =>
          targetStanding(_captures(grouped[key]!), rule);
      expect(of('NGC0891'), TargetStanding.project);
      expect(of('NGC 7331'), TargetStanding.capture);
      expect(of('M1'), TargetStanding.capture);
      final calibration = await owner.db.imagesDao.getAllImages();
      expect(
        targetStanding(
          _captures([
            for (final f in calibration)
              if (f.targetId == owner.calib) f,
          ]),
          rule,
        ),
        TargetStanding.capture,
      );
    });

    test('names that are not one catalog object stay apart', () async {
      final grouped = await loadDarkroomTargets(
        owner.db,
        readHeader: (_) async => FrameHeader(const {}),
        identity: CatalogIdentity<String>(const []),
      );
      expect(grouped['M1']!.length, 4);
      expect(grouped['NGC1952']!.length, 4);
    });

    test('a target becomes a project as soon as its lights qualify', () async {
      const rule = ProjectRule();
      var grouped = await _group(owner.db);
      expect(
        targetStanding(_captures(grouped['M1']!), rule),
        TargetStanding.capture,
      );
      for (var i = 0; i < 4; i++) {
        await owner.db
            .into(owner.db.capturedImages)
            .insert(
              CapturedImagesCompanion.insert(
                filePath: '/data/m1_more_$i.fits',
                fileName: 'm1_more_$i.fits',
                exposureDuration: 300,
                capturedAt: DateTime(2026, 11, 3, 22, i),
                targetId: Value(owner.m1),
                producingRunId: const Value('run-m1-2'),
              ),
            );
      }
      grouped = await _group(owner.db);
      expect(
        targetStanding(_captures(grouped['M1']!), rule),
        TargetStanding.project,
      );
    });

    test('grouping and classifying change nothing in the database', () async {
      final images = await _count(owner.db, 'captured_images');
      final targets = await _count(owner.db, 'targets');
      final before = await owner.db.imagesDao.getAllImages();
      await _group(owner.db);
      expect(await _count(owner.db, 'captured_images'), images);
      expect(await _count(owner.db, 'targets'), targets);
      final after = await owner.db.imagesDao.getAllImages();
      expect(
        {for (final f in after) f.id: f.targetId},
        {for (final f in before) f.id: f.targetId},
      );
    });
  });

  group('corrections', () {
    late _Owner owner;
    late _Trash trash;
    late DarkroomTargetEdits edits;
    setUp(() async {
      owner = await _seed();
      trash = _Trash();
      edits = DarkroomTargetEdits(owner.db, trash: () async => trash);
    });
    tearDown(() => owner.db.close());

    test('hide and unhide a target, and undo', () async {
      final hidden = await edits.place('NGC0891', TargetPlacement.hidden);
      var placements = await TargetPlacements.load(owner.db.settingsDao);
      expect(placements.of('NGC0891'), TargetPlacement.hidden);
      expect(placements.of('ngc 0891'), TargetPlacement.hidden);
      await edits.undo(hidden);
      placements = await TargetPlacements.load(owner.db.settingsDao);
      expect(placements.of('NGC0891'), TargetPlacement.auto);
      await edits.place('NGC0891', TargetPlacement.hidden);
      await edits.place('NGC0891', TargetPlacement.auto);
      placements = await TargetPlacements.load(owner.db.settingsDao);
      expect(placements.of('NGC0891'), TargetPlacement.auto);
    });

    test(
      'merge files the lights and masters under the target, and undo',
      () async {
        final masters = IntegratedMastersDao(owner.db);
        final master = await masters.insertMaster(
          targetId: owner.snap,
          name: 'NGC 7331 · L',
          status: IntegratedMasterStatus.finalized,
          accumulationMode: AccumulationMode.batch,
          frameCount: 2,
          totalIntegrationSeconds: 4,
        );
        final rows = await owner.db.targetsDao.getAllTargets();
        var grouped = await _group(owner.db);
        final from = DarkroomTargetGroup(
          key: 'NGC 7331',
          frames: grouped['NGC 7331']!,
          row: rows.firstWhere((r) => r.id == owner.snap),
          masters: [(await masters.getById(master))!],
        );
        final edit = await edits.merge(
          from,
          _groupOf(grouped, 'NGC0891', rows),
        );
        grouped = await _group(owner.db);
        expect(grouped['NGC 7331'], isNull);
        expect(grouped['NGC0891']!.length, 23);
        expect((await masters.getById(master))!.targetId, owner.ngc891);
        // The merged-away target stays in the target list.
        expect(await owner.db.targetsDao.getTargetById(owner.snap), isNotNull);

        await edits.undo(edit);
        grouped = await _group(owner.db);
        expect(grouped['NGC 7331']!.length, 2);
        expect(grouped['NGC0891']!.length, 21);
        expect((await masters.getById(master))!.targetId, owner.snap);
      },
    );

    test('rename a target, and a name already taken is refused', () async {
      final rows = await owner.db.targetsDao.getAllTargets();
      var grouped = await _group(owner.db);
      await edits.place('NGC 7331', TargetPlacement.project);
      final edit = await edits.rename(
        _groupOf(grouped, 'NGC 7331', rows),
        'Deer Lick test',
      );
      grouped = await _group(owner.db);
      expect(grouped['Deer Lick test']!.length, 2);
      expect(
        (await TargetPlacements.load(
          owner.db.settingsDao,
        )).of('Deer Lick test'),
        TargetPlacement.project,
      );
      await expectLater(
        edits.rename(_groupOf(grouped, 'Deer Lick test', rows), 'ngc0891'),
        throwsStateError,
      );
      await edits.undo(edit);
      grouped = await _group(owner.db);
      expect(grouped['NGC 7331']!.length, 2);
    });

    test('naming lights with no target makes them a target', () async {
      final grouped = await _group(owner.db);
      final edit = await edits.rename(
        DarkroomTargetGroup(
          key: darkroomNoTargetKey,
          frames: grouped[darkroomNoTargetKey]!,
        ),
        'Focus tests',
      );
      var after = await _group(owner.db);
      expect(after['Focus tests']!.length, 2);
      expect(after.unidentified, isEmpty);
      await edits.undo(edit);
      after = await _group(owner.db);
      expect(after[darkroomNoTargetKey]!.length, 2);
      expect(await owner.db.targetsDao.getTargetById(edit.createdRow!), isNull);
    });

    test('assign stray lights to a target, and undo', () async {
      final grouped = await _group(owner.db);
      final stray = grouped[darkroomNoTargetKey]!;
      final ngc = (await owner.db.targetsDao.getTargetById(owner.ngc891))!;
      final onField = [
        for (final f in stray)
          if (darkroomTargetsAt(f, [ngc]).isNotEmpty) f,
      ];
      expect(onField, hasLength(1));
      final edit = await edits.assign(onField, ngc);
      expect((await _group(owner.db))['NGC0891']!.length, 22);
      await edits.undo(edit);
      expect((await _group(owner.db))['NGC0891']!.length, 21);
    });

    test(
      'delete lists what goes and removes nothing until confirmed',
      () async {
        final rows = await owner.db.targetsDao.getAllTargets();
        final grouped = await _group(owner.db);
        final images = await _count(owner.db, 'captured_images');
        final plan = await edits.planDeletion(
          _groupOf(grouped, 'NGC 7331', rows),
        );
        expect(plan.lightFiles, hasLength(2));
        expect(plan.targetRows.map((r) => r.name), ['NGC 7331']);
        expect(plan.restorable, isTrue);
        // Planning touched nothing.
        expect(trash.removed, isEmpty);
        expect(await _count(owner.db, 'captured_images'), images);

        final failed = await edits.delete(plan);
        expect(failed, isEmpty);
        expect(trash.removed, plan.files);
        expect(await _count(owner.db, 'captured_images'), images - 2);
        expect(await owner.db.targetsDao.getTargetById(owner.snap), isNull);
        // Nothing else was touched.
        expect((await _group(owner.db))['NGC0891']!.length, 21);
      },
    );
  });

  group('the platform trash', () {
    test('a file that is not on this computer is skipped', () async {
      final trash = await PlatformFileTrash.detect();
      expect(await trash.remove(['/nowhere/at/all.fits']), isEmpty);
    });

    test('without a trash a file is deleted for good', () async {
      final dir = await Directory.systemTemp.createTemp('trash-test-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/l.fits')..writeAsStringSync('x');
      final trash = await PlatformFileTrash.detect();
      if (trash.restorable) return;
      expect(await trash.remove([file.path]), isEmpty);
      expect(file.existsSync(), isFalse);
    });
  });

  group('Plan > Targets cleanup', () {
    test('removes only saved targets the rule calls unused', () async {
      final owner = await _seed();
      addTearDown(owner.db.close);
      // Only M101 has nothing captured with its id; the snapshot solved on
      // its field records no target.
      expect(await owner.db.targetsDao.countUntrackedTargets(), 1);
      expect(await owner.db.targetsDao.deleteUntrackedTargets(), 1);
      expect(await owner.db.targetsDao.getTargetById(owner.m101), isNull);
      expect(await owner.db.targetsDao.getTargetById(owner.calib), isNotNull);
    });
  });
}
