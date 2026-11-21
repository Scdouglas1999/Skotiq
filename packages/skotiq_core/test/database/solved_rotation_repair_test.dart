import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/solved_rotation_repair.dart';

// The rig's NGC 7380 rows of 2026-09-14 to 10-06 store a rotation of
// -158.4 degrees while their own CD matrix (a mirrored Newtonian frame) says
// -21.4; ASTAP's CROTA2 for the same solve is -21.41.
void main() {
  late SkotiqDatabase db;
  late ImagesDao dao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = ImagesDao(db);
  });
  tearDown(() => db.close());

  Future<int> solvedFrame(
    String name, {
    required double rotation,
    double? cd11,
    double? cd12,
    double? cd21,
    double? cd22,
  }) async {
    final id = await dao.insertSequenceFrame(
      filePath: '/lights/$name',
      fileName: name,
      fileFormat: 'fits',
      exposureDuration: 5,
      capturedAt: DateTime.utc(2026, 9, 15, 1, 26, 11),
      isAccepted: true,
      producingNodeId: 'n',
    );
    await dao.updatePlateSolveResult(
      id,
      solvedRa: 341.799 / 15,
      solvedDec: 58.136,
      solvedRotation: rotation,
      solvedPixelScale: 0.788,
      solvedCd1_1: cd11,
      solvedCd1_2: cd12,
      solvedCd2_1: cd21,
      solvedCd2_2: cd22,
    );
    return id;
  }

  test('an old row takes the rotation its own CD matrix gives', () async {
    final stale = await solvedFrame(
      'old.fits',
      rotation: -158.587,
      cd11: 2.036925663673e-4,
      cd12: 7.989092543574e-5,
      cd21: -7.991533991366e-5,
      cd22: 2.037815449009e-4,
    );
    final scalarOnly = await solvedFrame('scalar.fits', rotation: 12.0);

    expect(await repairSolvedRotationFromCd(db), 1);
    expect(
      (await dao.getImageById(stale))!.solvedRotation,
      closeTo(-21.42, 0.01),
    );
    expect((await dao.getImageById(scalarOnly))!.solvedRotation, 12.0);

    // Idempotent: a second pass changes nothing.
    expect(await repairSolvedRotationFromCd(db), 0);
  });

  test(
    'rows already within half a degree, and a singular matrix, stay put',
    () async {
      const cd11 = 2.036925663673e-4;
      const cd12 = 7.989092543574e-5;
      const cd21 = -7.991533991366e-5;
      const cd22 = 2.037815449009e-4;
      final want = rotationFromStoredCd(cd11, cd12, cd21, cd22);

      final close = await solvedFrame(
        'close.fits',
        rotation: want + 0.4,
        cd11: cd11,
        cd12: cd12,
        cd21: cd21,
        cd22: cd22,
      );
      final far = await solvedFrame(
        'far.fits',
        rotation: want + 2,
        cd11: cd11,
        cd12: cd12,
        cd21: cd21,
        cd22: cd22,
      );
      final singular = await solvedFrame(
        'singular.fits',
        rotation: 12,
        cd11: 1,
        cd12: 0,
        cd21: 0,
        cd22: 0,
      );
      final missing = await solvedFrame('missing.fits', rotation: 4);
      await db.customStatement(
        'UPDATE captured_images SET solved_rotation = NULL, '
        'solved_cd1_1 = ?, solved_cd1_2 = ?, solved_cd2_1 = ?, solved_cd2_2 = ? '
        'WHERE id = ?',
        [cd11, cd12, cd21, cd22, missing],
      );

      expect(await repairSolvedRotationFromCd(db), 2);
      expect(
        (await dao.getImageById(close))!.solvedRotation,
        closeTo(want + 0.4, 1e-9),
      );
      expect(
        (await dao.getImageById(far))!.solvedRotation,
        closeTo(want, 0.01),
      );
      expect((await dao.getImageById(singular))!.solvedRotation, 12);
      expect(
        (await dao.getImageById(missing))!.solvedRotation,
        closeTo(want, 0.01),
      );
    },
  );

  test('every rotation rewrite commits in one transaction', () async {
    final trace = _SqlTrace();
    final traced = SkotiqDatabase.forTesting(
      NativeDatabase.memory().interceptWith(trace),
    );
    addTearDown(traced.close);
    final tracedDao = ImagesDao(traced);
    Future<int> frame(String name, double rotation) async {
      final id = await tracedDao.insertSequenceFrame(
        filePath: '/lights/$name',
        fileName: name,
        fileFormat: 'fits',
        exposureDuration: 5,
        capturedAt: DateTime.utc(2026, 9, 15),
        isAccepted: true,
        producingNodeId: 'n',
      );
      await tracedDao.updatePlateSolveResult(
        id,
        solvedRa: 1,
        solvedDec: 2,
        solvedRotation: rotation,
        solvedPixelScale: 1,
        solvedCd1_1: 2.036925663673e-4,
        solvedCd1_2: 7.989092543574e-5,
        solvedCd2_1: -7.991533991366e-5,
        solvedCd2_2: 2.037815449009e-4,
      );
      return id;
    }

    await frame('a.fits', -158);
    await frame('b.fits', -158);
    trace.events.clear();

    expect(await repairSolvedRotationFromCd(traced), 2);
    expect(trace.events.first, 'begin');
    expect(trace.events.where((e) => e == 'write'), hasLength(2));
    expect(trace.events.last, 'commit');
  });

  test('a row that already agrees is left alone, sky parity included', () {
    // CD of a standard-parity frame at rotation 30: [[-s cos, s sin],
    // [s sin, s cos]].
    expect(
      rotationFromStoredCd(-1.9e-4, 1.1e-4, 1.1e-4, 1.9e-4),
      closeTo(30.07, 0.01),
    );
  });
}

class _SqlTrace extends QueryInterceptor {
  final events = <String>[];

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    events.add('begin');
    return super.beginTransaction(parent);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) {
    events.add('commit');
    return super.commitTransaction(inner);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.startsWith('UPDATE captured_images SET solved_rotation')) {
      events.add('write');
    }
    return super.runCustom(executor, statement, args);
  }
}
