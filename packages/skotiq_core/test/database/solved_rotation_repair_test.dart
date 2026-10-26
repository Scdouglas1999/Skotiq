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

  test('a row that already agrees is left alone, sky parity included', () {
    // CD of a standard-parity frame at rotation 30: [[-s cos, s sin],
    // [s sin, s cos]].
    expect(
      rotationFromStoredCd(-1.9e-4, 1.1e-4, 1.1e-4, 1.9e-4),
      closeTo(30.07, 0.01),
    );
  });
}
