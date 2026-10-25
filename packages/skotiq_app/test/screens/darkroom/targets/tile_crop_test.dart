import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/targets/tile_crop.dart';
import 'package:skotiq_core/skotiq_core.dart';

IntegratedMaster _master({
  double? crval1,
  double? crval2,
  double? crpix1,
  double? crpix2,
  double? cd,
}) =>
    IntegratedMaster(
      id: 1,
      targetId: 1,
      name: 'NGC 891 L',
      masterFitsPath: '/m/L.fits',
      previewPngPath: '/m/L.png',
      sidecarPath: null,
      rejectionMapPath: null,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.runningWeightedMean,
      channels: 1,
      width: 1000,
      height: 800,
      frameCount: 40,
      totalIntegrationSeconds: 3600,
      filter: 'L',
      settingsJson: '{}',
      statsJson: '{}',
      createdAt: DateTime(2026, 10, 22),
      updatedAt: DateTime(2026, 10, 22),
      wcsCrval1: crval1,
      wcsCrval2: crval2,
      wcsCrpix1: crpix1,
      wcsCrpix2: crpix2,
      wcsCd1_1: cd == null ? null : -cd,
      wcsCd1_2: cd == null ? null : 0,
      wcsCd2_1: cd == null ? null : 0,
      wcsCd2_2: cd,
    );

void main() {
  late SkotiqDatabase db;

  setUp(() => db = SkotiqDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<DbTarget> target({double? sizeArcmin}) async {
    await db.targetsDao.createTarget(
      TargetsCompanion.insert(
        name: 'NGC 891',
        ra: 2.37594722,
        dec: 42.34913889,
        sizeArcmin: Value(sizeArcmin),
      ),
    );
    return (await db.targetsDao.getAllTargets()).single;
  }

  test('without a solve the tile is centered on the image at the default span',
      () async {
    final crop = DarkroomTileCrop.forMaster(_master(), await target());
    expect(crop.center, const Offset(.5, .5));
    expect(crop.span, darkroomDefaultTileSpan);
  });

  test(
      'a solved master centers the tile on the target and sizes it from the '
      'target\'s size and the pixel scale', () async {
    final row = await target(sizeArcmin: 4);
    final crop = DarkroomTileCrop.forMaster(
      _master(
        crval1: row.ra * 15,
        crval2: row.dec,
        crpix1: 250.5,
        crpix2: 200.5,
        cd: 1 / 3600,
      ),
      row,
    );
    expect(crop.center.dx, closeTo(.25, 1e-6));
    expect(crop.center.dy, closeTo(.25, 1e-6));
    // 4' with margin at 1"/px is 336 px of the 800 px short side.
    expect(crop.span, closeTo(4 * 1.4 * 60 / 800, 1e-6));
  });

  test('a target off the image falls back to the image center', () async {
    final row = await target();
    final crop = DarkroomTileCrop.forMaster(
      _master(
        crval1: row.ra * 15 + 2,
        crval2: row.dec,
        crpix1: 500,
        crpix2: 400,
        cd: 1 / 3600,
      ),
      row,
    );
    expect(crop.center, const Offset(.5, .5));
  });
}
