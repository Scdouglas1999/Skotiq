// Pins the results of the ImagesDao methods that read and write the
// provenance, thumbnail, WCS and plate-solve columns of captured_images: their
// return values, their null handling, ORDER BY ties, what each write leaves in
// the row, and which writes wake a watcher on the table.

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';

import 'pin_harness.dart';

Object? _encode(Object value) => switch (value) {
  DbCapturedImage c => {
    ...c.toJson(),
    'capturedAt': c.capturedAt,
    'createdAt': c.createdAt,
    'atlasFoldedAt': c.atlasFoldedAt,
  },
  ProducingNodeThumbnail t => {
    'id': t.id,
    'filePath': t.filePath,
    'fileName': t.fileName,
    'filter': t.filter,
    'frameType': t.frameType,
    'hfr': t.hfr,
    'eccentricity': t.eccentricity,
    'fwhm': t.fwhm,
    'starCount': t.starCount,
    'exposureDuration': t.exposureDuration,
    'capturedAt': t.capturedAt,
    'isAccepted': t.isAccepted,
    'rejectionReason': t.rejectionReason,
    'runtimeGrade': t.runtimeGrade,
    'producingNodeId': t.producingNodeId,
    'producingRunId': t.producingRunId,
    'gradeKind': t.gradeKind,
  },
  _ => null,
};

const _rowColumns =
    'id, file_path, file_size, session_id, target_id, frame_type, filter, '
    'hfr, star_count, quality_score, captured_at, created_at, is_accepted, '
    'rejection_reason, producing_node_id, producing_run_id, runtime_grade, '
    'eccentricity, fwhm, is_plate_solved, solved_ra, solved_dec, '
    'solved_rotation, solved_pixel_scale, solved_cd1_1, solved_cd1_2, '
    'solved_cd2_1, solved_cd2_2, solved_sip, thumbnail_path, '
    'plate_solve_failed_at, sensor_temp, cooler_power, mount_ra, mount_dec, '
    'mount_altitude, mount_azimuth, pier_side, focuser_position, '
    'focuser_temp, rotator_angle, gain, "offset", bin_x, bin_y, file_format, '
    'exposure_duration';

void main() {
  late SkotiqDatabase db;
  late PinSeed seed;
  late Directory dir;

  setUp(() async {
    db = openPinDatabase();
    seed = await PinSeed.create(db);
    dir = await Directory.systemTemp.createTemp('pin_images_');
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('ImagesDao provenance and solve columns are pinned', () async {
    final pins = PinRecorder('images_dao', encode: _encode)
      ..scrub[dir.path] = '<tmp>';
    final dao = ImagesDao(db);
    final s0 = seed.sessions[0];

    Future<void> dumpRows(String label) async {
      final rows = await db
          .customSelect('SELECT $_rowColumns FROM captured_images ORDER BY id')
          .get();
      pins.record('$label :: captured_images', [for (final r in rows) r.data]);
    }

    // Writes that wake a watcher of the table, counted per write.
    var wakes = 0;
    final watch = db.select(db.capturedImages).watch().listen((_) => wakes++);
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 30));
    Future<void> wakesAfter(
      String label,
      Future<Object?> Function() body,
    ) async {
      await settle();
      final before = wakes;
      await pins(label, body);
      await settle();
      await settle();
      pins.record('$label :: wakes watchers', wakes > before);
    }

    final onDisk = File('${dir.path}/on_disk.fits')
      ..writeAsBytesSync(List.filled(2880, 1));

    await pins('empty node thumbnails', () {
      return dao.getImagesByProducingNode(producingNodeId: 'n1');
    });
    await pins('empty node count', () {
      return dao.countImagesByProducingNode(producingNodeId: 'n1');
    });
    await pins('empty run images', () {
      return dao.getImagesByProducingRun(producingRunId: '1');
    });
    await pins('empty run count', () {
      return dao.countImagesByProducingRun(producingRunId: '1');
    });
    await pins('fwhm for empty session', () => dao.getFwhmForSession(999));
    await pins('thumbnail path missing row', () => dao.getThumbnailPath(999));
    await pins('wcs missing row', () => dao.getStoredWcsDistortion(999));
    await pins('fwhm missing row', () => dao.getFwhm(999));

    await wakesAfter(
      'insertSequenceFrame full',
      () => dao.insertSequenceFrame(
        filePath: onDisk.path,
        fileName: 'on_disk.fits',
        fileFormat: 'fits',
        exposureDuration: 300,
        capturedAt: pinT(100),
        isAccepted: true,
        producingNodeId: 'n1',
        producingRunId: '7',
        runtimeGrade: 'pass',
        sessionId: s0,
        targetId: seed.targets[0],
        filter: 'Ha',
        hfr: 2.25,
        starCount: 812,
        eccentricity: 0.41,
        gain: 100,
        offset: 30,
        binX: 2,
        binY: 2,
        qualityScore: 88.5,
        sensorTemp: -10,
        coolerPower: 42.5,
        mountRa: 2.5,
        mountDec: 40.75,
        mountAltitude: 61,
        mountAzimuth: 120.5,
        pierSide: 'west',
        focuserPosition: 6620,
        focuserTemp: 4.5,
        rotatorAngle: 90,
      ),
    );
    await pins(
      'insertSequenceFrame minimal missing file',
      () => dao.insertSequenceFrame(
        filePath: '${dir.path}/never_written.fits',
        fileName: 'never_written.fits',
        fileFormat: 'xisf',
        exposureDuration: 60,
        capturedAt: pinT(100),
        isAccepted: false,
        producingNodeId: 'n1',
        rejectionReason: 'trailed',
        frameType: FrameType.dark,
      ),
    );
    await pins(
      'insertSequenceFrame empty path',
      () => dao.insertSequenceFrame(
        filePath: '',
        fileName: '',
        fileFormat: 'fits',
        exposureDuration: 1,
        capturedAt: pinT(90),
        isAccepted: true,
        producingNodeId: 'n1',
        producingRunId: '7',
        runtimeGrade: 'borderline',
      ),
    );
    await pins(
      'insertSequenceFrame other node',
      () => dao.insertSequenceFrame(
        filePath: '/frames/n2.fits',
        fileName: 'n2.fits',
        fileFormat: 'fits',
        exposureDuration: 120,
        capturedAt: pinT(95),
        isAccepted: true,
        producingNodeId: 'n2',
        producingRunId: '8',
        sessionId: s0,
      ),
    );
    await dumpRows('after inserts');

    final seeded = seed.images;
    await wakesAfter(
      'stampProducingNode all',
      () => dao.stampProducingNode(
        imageId: seeded[0],
        producingNodeId: 'n1',
        producingRunId: '7',
        runtimeGrade: 'reject',
        eccentricity: 0.6,
        fwhm: 3.5,
      ),
    );
    await pins(
      'stampProducingNode some',
      () => dao.stampProducingNode(
        imageId: seeded[1],
        producingNodeId: 'n1',
        fwhm: 2.75,
      ),
    );
    await wakesAfter(
      'stampProducingNode none',
      () => dao.stampProducingNode(imageId: seeded[2]),
    );
    await pins(
      'stampProducingNode missing row',
      () => dao.stampProducingNode(imageId: 999, runtimeGrade: 'pass'),
    );
    await pins(
      'stampProducingNode keeps unspecified',
      () => dao.stampProducingNode(imageId: seeded[0], runtimeGrade: 'pass'),
    );

    await wakesAfter(
      'setThumbnailPath',
      () => dao.setThumbnailPath(seeded[0], '/thumbs/a.jpg'),
    );
    await pins('setThumbnailPath empty clears', () {
      return dao.setThumbnailPath(seeded[1], '');
    });
    await pins('setThumbnailPath null clears', () {
      return dao.setThumbnailPath(7, null);
    });
    await pins('setThumbnailPath missing row', () {
      return dao.setThumbnailPath(999, '/x.jpg');
    });

    await wakesAfter(
      'updatePlateSolveResult with CD',
      () => dao.updatePlateSolveResult(
        seeded[2],
        solvedRa: 10.5,
        solvedDec: 41.2,
        solvedRotation: 12.5,
        solvedPixelScale: 1.25,
        solvedCd1_1: -0.0003,
        solvedCd1_2: 0.00002,
        solvedCd2_1: -0.00002,
        solvedCd2_2: -0.0003,
        solvedSip: '{"a":[[0]]}',
      ),
    );
    await pins(
      'updatePlateSolveResult partial CD ignored',
      () => dao.updatePlateSolveResult(
        seeded[3],
        solvedRa: 1,
        solvedDec: 2,
        solvedRotation: 3,
        solvedPixelScale: 4,
        solvedCd1_1: 1,
        solvedCd2_2: 1,
      ),
    );
    await pins(
      'updatePlateSolveResult CD without SIP',
      () => dao.updatePlateSolveResult(
        seeded[4],
        solvedRa: 5,
        solvedDec: 6,
        solvedRotation: 7,
        solvedPixelScale: 8,
        solvedCd1_1: 0.1,
        solvedCd1_2: 0.2,
        solvedCd2_1: 0.3,
        solvedCd2_2: 0.4,
      ),
    );
    await db.customStatement(
      "UPDATE captured_images SET solved_sip = 'old' WHERE id = ${seeded[4]}",
    );
    await pins(
      'updatePlateSolveResult CD again clears SIP',
      () => dao.updatePlateSolveResult(
        seeded[4],
        solvedRa: 5,
        solvedDec: 6,
        solvedRotation: 7,
        solvedPixelScale: 8,
        solvedCd1_1: 0.1,
        solvedCd1_2: 0.2,
        solvedCd2_1: 0.3,
        solvedCd2_2: 0.4,
      ),
    );

    final failedIds = <Set<int>>[];
    final failedSub = dao.watchPlateSolveFailedIds().listen(failedIds.add);
    await settle();
    await wakesAfter(
      'markPlateSolveFailed unsolved',
      () => dao.markPlateSolveFailed('/frames/f5.fits', at: pinT(200)),
    );
    await pins(
      'markPlateSolveFailed solved frame',
      () => dao.markPlateSolveFailed('/frames/f2.fits', at: pinT(200)),
    );
    await pins(
      'markPlateSolveFailed unknown path',
      () => dao.markPlateSolveFailed('/nowhere.fits'),
    );
    await pins(
      'markPlateSolveFailed default now',
      () => dao.markPlateSolveFailed('/frames/n2.fits'),
    );
    await settle();
    await settle();
    pins.record('watchPlateSolveFailedIds emissions', failedIds);
    await failedSub.cancel();
    await dumpRows('after writes');

    await pins('getThumbnailPath set', () => dao.getThumbnailPath(seeded[0]));
    await pins('getThumbnailPath null', () => dao.getThumbnailPath(seeded[1]));
    await pins(
      'getThumbnailPath predicted',
      () => dao.getThumbnailPath(seeded.last + 4),
    );
    await pins('listImagesForThumbnailBackfill', () {
      return dao.listImagesForThumbnailBackfill();
    });
    await pins('getStoredWcsDistortion full', () {
      return dao.getStoredWcsDistortion(seeded[2]);
    });
    await pins('getStoredWcsDistortion none', () {
      return dao.getStoredWcsDistortion(seeded[3]);
    });
    await pins('getFwhm set', () => dao.getFwhm(seeded[0]));
    await pins('getFwhm null', () => dao.getFwhm(seeded[2]));
    await pins('getFwhmForSession s0', () => dao.getFwhmForSession(s0));
    await pins('getFwhmForSession s1', () {
      return dao.getFwhmForSession(seed.sessions[1]);
    });

    await pins('node n1 all runs', () {
      return dao.getImagesByProducingNode(producingNodeId: 'n1');
    });
    await pins('node n1 run 7', () {
      return dao.getImagesByProducingNode(
        producingNodeId: 'n1',
        producingRunId: '7',
      );
    });
    await pins('node n1 limit 2', () {
      return dao.getImagesByProducingNode(producingNodeId: 'n1', limit: 2);
    });
    await pins('node n1 watch first', () {
      return dao.watchImagesByProducingNode(producingNodeId: 'n1').first;
    });
    await pins('node n1 run 7 watch first', () {
      return dao
          .watchImagesByProducingNode(
            producingNodeId: 'n1',
            producingRunId: '7',
          )
          .first;
    });
    await pins('node n1 count', () {
      return dao.countImagesByProducingNode(producingNodeId: 'n1');
    });
    await pins('node n1 run 7 count', () {
      return dao.countImagesByProducingNode(
        producingNodeId: 'n1',
        producingRunId: '7',
      );
    });
    await pins('node n9 count', () {
      return dao.countImagesByProducingNode(producingNodeId: 'n9');
    });

    // The strip's watcher sees a stamp on a row it already lists.
    final strip = <List<ProducingNodeThumbnail>>[];
    final stripSub = dao
        .watchImagesByProducingNode(producingNodeId: 'n2')
        .listen(strip.add);
    await settle();
    await dao.stampProducingNode(
      imageId: seeded.last + 4,
      runtimeGrade: 'pass',
    );
    await settle();
    await settle();
    pins.record('strip emissions after a stamp', strip.length);
    await stripSub.cancel();

    await pins('run 7 images', () {
      return dao.getImagesByProducingRun(producingRunId: '7');
    });
    await pins('run 7 images page', () {
      return dao.getImagesByProducingRun(
        producingRunId: '7',
        limit: 1,
        offset: 1,
      );
    });
    await pins('run 7 count', () {
      return dao.countImagesByProducingRun(producingRunId: '7');
    });

    await db.customStatement(
      'UPDATE captured_images SET file_size = NULL WHERE id IN (1, 2, 7)',
    );
    await db.customInsert(
      'INSERT INTO captured_images (file_path, file_name, exposure_duration, '
      "captured_at) VALUES ('', 'blank', 1, ?)",
      variables: [Variable.withInt(pinT(1).millisecondsSinceEpoch ~/ 1000)],
    );
    await db.customStatement(
      "UPDATE captured_images SET file_path = '${onDisk.path}' WHERE id = 2",
    );
    await pins('backfillMissingFileSizes', dao.backfillMissingFileSizes);
    await dumpRows('after backfill');

    await watch.cancel();
    pins.verify();
  });
}
