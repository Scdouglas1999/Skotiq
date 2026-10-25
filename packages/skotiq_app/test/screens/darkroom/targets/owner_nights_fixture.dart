import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Minutes between subs, as the owner's 120 s RGB and 90 s L runs cycle.
const int ownerCadenceMinutes = 3;

/// Evenings the owner imaged NGC 891, oldest first.
final ownerEvenings = [
  DateTime(2026, 10, 20),
  DateTime(2026, 10, 21),
  DateTime(2026, 10, 22),
  DateTime(2026, 10, 23),
];

/// NGC 891's catalog position.
const double ngc891Ra = 2.3759;
const double ngc891Dec = 42.349;

/// The owner's four nights of NGC 891, shaped like the real database:
///
/// * Oct 20: 20:33 to 23:30 West, all kept. The current masters (L, R, G, B
///   and a color image) were built from this night only.
/// * Oct 21: 20:33 to 00:30 West, a pause, a meridian flip at 01:36, then
///   East to 03:00, all kept.
/// * Oct 22: 20:58 to 00:46 West, then nothing (a pause to dawn).
/// * Oct 23: 20:33 to 00:42 West, flip at 01:36, East to 03:28, then five
///   subs whose stars are gone, then five pointed half a degree off.
class OwnerNights {
  OwnerNights(this.db, this.target, this.masters);

  final SkotiqDatabase db;
  final int target;

  /// Master ids by filter; `RGB` for the color image.
  final Map<String, int> masters;
}

Future<OwnerNights> seedOwnerNights({String targetName = 'NGC 891'}) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final target = await db.targetsDao.createTarget(
    TargetsCompanion.insert(
      name: targetName,
      ra: ngc891Ra,
      dec: ngc891Dec,
      objectType: const Value('Galaxy'),
      constellation: const Value('And'),
    ),
  );
  var n = 0;
  final night1Kept = <String, List<int>>{};
  Future<int> sub(
    DateTime at, {
    required String side,
    bool kept = true,
    String? reason,
    double raOffsetHours = 0,
  }) async {
    final filter = 'LRGB'[n % 4];
    n++;
    return db.imagesDao.createImage(
      CapturedImagesCompanion.insert(
        targetId: Value(target),
        filePath:
            '/data/NGC891/NGC0891_${filter}_${n.toString().padLeft(4, '0')}.fits',
        fileName: 'NGC0891_${filter}_${n.toString().padLeft(4, '0')}.fits',
        exposureDuration: filter == 'L' ? 90 : 120,
        filter: Value(filter),
        gain: const Value(76),
        offset: const Value(15),
        sensorTemp: const Value(-10),
        pierSide: Value(side),
        mountRa: Value(ngc891Ra + raOffsetHours),
        mountDec: const Value(ngc891Dec),
        isAccepted: Value(kept),
        rejectionReason: Value(reason),
        capturedAt: at,
      ),
    );
  }

  Future<void> run(
    DateTime from,
    DateTime to, {
    required String side,
    bool kept = true,
    String? reason,
    double raOffsetHours = 0,
    List<int>? into,
  }) async {
    for (var t = from;
        t.isBefore(to);
        t = t.add(const Duration(minutes: ownerCadenceMinutes))) {
      final filter = 'LRGB'[n % 4];
      final id = await sub(
        t,
        side: side,
        kept: kept,
        reason: reason,
        raOffsetHours: raOffsetHours,
      );
      if (into != null && kept) {
        night1Kept.putIfAbsent(filter, () => []).add(id);
      }
    }
  }

  DateTime at(int evening, int hour, int minute) => DateTime(
        ownerEvenings[evening].year,
        ownerEvenings[evening].month,
        ownerEvenings[evening].day,
        hour,
        minute,
      );

  await run(at(0, 20, 33), at(0, 23, 30), side: 'West', into: []);
  await run(at(1, 20, 33), at(1, 24, 30), side: 'West');
  await run(at(1, 25, 36), at(1, 27, 0), side: 'East');
  await run(at(2, 20, 58), at(2, 24, 46), side: 'West');
  await run(at(3, 20, 33), at(3, 24, 42), side: 'West');
  await run(at(3, 25, 36), at(3, 27, 28), side: 'East');
  await run(
    at(3, 27, 28),
    at(3, 27, 43),
    side: 'East',
    kept: false,
    reason: 'no stars detected (clouds, trailing, off-target slew, or an '
        'obstructed aperture)',
  );
  await run(
    at(3, 27, 43),
    at(3, 27, 58),
    side: 'East',
    kept: false,
    reason: 'HFR 4.10 px exceeds absolute threshold 3.50 px',
    raOffsetHours: .05,
  );

  final mastersDao = IntegratedMastersDao(db);
  final masters = <String, int>{};
  final built = DateTime(2026, 10, 21, 9);
  for (final filter in ['L', 'R', 'G', 'B']) {
    final ids = night1Kept[filter]!;
    final id = await mastersDao.insertMaster(
      targetId: target,
      name: 'NGC0891 · $filter',
      masterFitsPath: '/masters/NGC0891_$filter.fits',
      previewPngPath: '/masters/NGC0891_$filter.png',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      width: 4656,
      height: 3520,
      frameCount: ids.length,
      totalIntegrationSeconds: ids.length * (filter == 'L' ? 90.0 : 120.0),
      filter: filter,
      createdAt: built,
      updatedAt: built,
    );
    for (final image in ids) {
      await mastersDao.recordFoldedFrame(masterId: id, imageId: image);
    }
    masters[filter] = id;
  }
  masters['RGB'] = await mastersDao.insertMaster(
    targetId: target,
    name: 'NGC0891 LRGB',
    masterFitsPath: '/masters/NGC0891_RGB.fits',
    previewPngPath: '/masters/NGC0891_LRGB.jpg',
    status: IntegratedMasterStatus.finalized,
    accumulationMode: AccumulationMode.batch,
    channels: 3,
    width: 4656,
    height: 3520,
    frameCount: 58,
    totalIntegrationSeconds: 6300,
    createdAt: built.add(const Duration(minutes: 10)),
    updatedAt: built.add(const Duration(minutes: 10)),
  );
  return OwnerNights(db, target, masters);
}
