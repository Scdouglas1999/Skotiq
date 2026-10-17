import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

/// Thumbnail — unit tests for the producing-node provenance
/// helpers added to `ImagesDao` in v30.
///
/// We exercise the raw-DDL columns (producing_node_id, producing_run_id,
/// runtime_grade, eccentricity) through the documented APIs:
///   * [ImagesDao.insertSequenceFrame] — the FrameAccepted/Rejected path.
///   * [ImagesDao.stampProducingNode]  — the ad-hoc capture upgrade path.
///   * [ImagesDao.getImagesByProducingNode] /
///     [ImagesDao.watchImagesByProducingNode] — the lookup feeding
///     `exposureNodeThumbnailsProvider`.
///   * [ImagesDao.countImagesByProducingNode] — the cheap count the tree
///     uses to decide whether to render the strip.
///
/// Each test runs on a fresh in-memory database so we don't have to clean
/// up across tests.
void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('insertSequenceFrame', () {
    test('persists producing_node_id and basic metrics', () async {
      final id = await imagesDao.insertSequenceFrame(
        filePath: '/captures/m31/L_0001.fits',
        fileName: 'L_0001.fits',
        fileFormat: 'fits',
        exposureDuration: 120.0,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 15, 0),
        isAccepted: true,
        producingNodeId: 'node-abc',
        producingRunId: 'run-7',
        runtimeGrade: 'pass',
        filter: 'L',
        hfr: 2.1,
        eccentricity: 0.32,
        starCount: 145,
      );
      expect(id, greaterThan(0));

      final rows = await imagesDao.getImagesByProducingNode(
        producingNodeId: 'node-abc',
      );
      expect(rows, hasLength(1));
      final row = rows.first;
      expect(row.producingNodeId, 'node-abc');
      expect(row.producingRunId, 'run-7');
      expect(row.runtimeGrade, 'pass');
      expect(row.hfr, closeTo(2.1, 1e-9));
      expect(row.eccentricity, closeTo(0.32, 1e-9));
      expect(row.starCount, 145);
      expect(row.gradeKind, 'pass');
    });

    test('returns multiple rows ordered by captured_at ascending', () async {
      for (var i = 0; i < 5; i++) {
        await imagesDao.insertSequenceFrame(
          filePath: '/captures/m31/L_$i.fits',
          fileName: 'L_$i.fits',
          fileFormat: 'fits',
          exposureDuration: 60,
          // Older timestamps for earlier indices so we can assert ordering
          // unambiguously.
          capturedAt: DateTime.utc(2026, 1, 1, 22, i, 0),
          isAccepted: true,
          producingNodeId: 'multi-node',
          runtimeGrade: 'pass',
          filter: 'L',
        );
      }
      final rows = await imagesDao.getImagesByProducingNode(
        producingNodeId: 'multi-node',
      );
      expect(rows, hasLength(5));
      for (var i = 0; i + 1 < rows.length; i++) {
        expect(
          rows[i].capturedAt.isBefore(rows[i + 1].capturedAt) ||
              rows[i].capturedAt.isAtSameMomentAs(rows[i + 1].capturedAt),
          isTrue,
        );
      }
    });

    test('rejected frame carries reason + reject grade kind', () async {
      await imagesDao.insertSequenceFrame(
        filePath: '/captures/m31/Reject/L_0007.fits',
        fileName: 'L_0007.fits',
        fileFormat: 'fits',
        exposureDuration: 120,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0, 0),
        isAccepted: false,
        producingNodeId: 'node-r',
        runtimeGrade: 'reject',
        rejectionReason: 'HFR 6.4 above threshold 3.5',
        filter: 'L',
        hfr: 6.4,
      );
      final rows = await imagesDao.getImagesByProducingNode(
        producingNodeId: 'node-r',
      );
      expect(rows.single.isAccepted, isFalse);
      expect(rows.single.rejectionReason, contains('HFR'));
      expect(rows.single.gradeKind, 'reject');
    });

    test('producing_run_id filter narrows the result set', () async {
      await imagesDao.insertSequenceFrame(
        filePath: '/r1/L.fits',
        fileName: 'L.fits',
        fileFormat: 'fits',
        exposureDuration: 60,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0, 0),
        isAccepted: true,
        producingNodeId: 'same-node',
        producingRunId: 'run-A',
      );
      await imagesDao.insertSequenceFrame(
        filePath: '/r2/L.fits',
        fileName: 'L.fits',
        fileFormat: 'fits',
        exposureDuration: 60,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 5, 0),
        isAccepted: true,
        producingNodeId: 'same-node',
        producingRunId: 'run-B',
      );

      final runA = await imagesDao.getImagesByProducingNode(
        producingNodeId: 'same-node',
        producingRunId: 'run-A',
      );
      expect(runA.map((r) => r.producingRunId), ['run-A']);

      final all = await imagesDao.getImagesByProducingNode(
        producingNodeId: 'same-node',
      );
      expect(all, hasLength(2));
    });
  });

  group('countImagesByProducingNode', () {
    test('returns 0 when no rows match', () async {
      final c = await imagesDao.countImagesByProducingNode(
        producingNodeId: 'never-existed',
      );
      expect(c, 0);
    });

    test('counts only rows for the given node', () async {
      for (var i = 0; i < 3; i++) {
        await imagesDao.insertSequenceFrame(
          filePath: '/n1/$i.fits',
          fileName: '$i.fits',
          fileFormat: 'fits',
          exposureDuration: 30,
          capturedAt: DateTime.utc(2026, 1, 1, i, 0, 0),
          isAccepted: true,
          producingNodeId: 'n1',
        );
      }
      await imagesDao.insertSequenceFrame(
        filePath: '/n2/0.fits',
        fileName: '0.fits',
        fileFormat: 'fits',
        exposureDuration: 30,
        capturedAt: DateTime.utc(2026, 1, 1, 0, 0, 0),
        isAccepted: true,
        producingNodeId: 'n2',
      );
      expect(
        await imagesDao.countImagesByProducingNode(producingNodeId: 'n1'),
        3,
      );
      expect(
        await imagesDao.countImagesByProducingNode(producingNodeId: 'n2'),
        1,
      );
    });
  });

  group('stampProducingNode', () {
    test('upgrades an existing row in place', () async {
      // Existing row (e.g. inserted by the ad-hoc captureImage path) has
      // no node id — stamping must populate it without rewriting the
      // file path or HFR.
      final id = await imagesDao.insertSequenceFrame(
        filePath: '/adhoc.fits',
        fileName: 'adhoc.fits',
        fileFormat: 'fits',
        exposureDuration: 10,
        capturedAt: DateTime.utc(2026, 1, 1, 23, 0, 0),
        isAccepted: true,
        producingNodeId: '',
      );
      // Note: insertSequenceFrame requires non-null producingNodeId so we
      // passed an empty string above; the strip's empty-string guard
      // would normally have kicked in. Test the upgrade path:
      await imagesDao.stampProducingNode(
        imageId: id,
        producingNodeId: 'stamped-node',
        runtimeGrade: 'pass',
        eccentricity: 0.41,
      );
      final rows = await imagesDao.getImagesByProducingNode(
        producingNodeId: 'stamped-node',
      );
      expect(rows, hasLength(1));
      expect(rows.single.id, id);
      expect(rows.single.runtimeGrade, 'pass');
      expect(rows.single.eccentricity, closeTo(0.41, 1e-9));
    });

    test('omitting fields leaves them unchanged', () async {
      final id = await imagesDao.insertSequenceFrame(
        filePath: '/a.fits',
        fileName: 'a.fits',
        fileFormat: 'fits',
        exposureDuration: 10,
        capturedAt: DateTime.utc(2026, 1, 1, 23, 0, 0),
        isAccepted: true,
        producingNodeId: 'starting-node',
        runtimeGrade: 'pass',
        eccentricity: 0.1,
      );
      // Stamp only the run id — grade and eccentricity must survive.
      await imagesDao.stampProducingNode(imageId: id, producingRunId: 'run-99');
      final rows = await imagesDao.getImagesByProducingNode(
        producingNodeId: 'starting-node',
      );
      expect(rows.single.producingRunId, 'run-99');
      expect(rows.single.runtimeGrade, 'pass');
      expect(rows.single.eccentricity, closeTo(0.1, 1e-9));
    });
  });

  group('watchImagesByProducingNode', () {
    test('emits a new value when a fresh row is inserted', () async {
      final stream = imagesDao.watchImagesByProducingNode(
        producingNodeId: 'live-node',
      );
      final received = <List<ProducingNodeThumbnail>>[];
      final sub = stream.listen(received.add);

      // Allow the initial empty emission to land before mutating.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await imagesDao.insertSequenceFrame(
        filePath: '/live/0.fits',
        fileName: '0.fits',
        fileFormat: 'fits',
        exposureDuration: 60,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0, 0),
        isAccepted: true,
        producingNodeId: 'live-node',
        runtimeGrade: 'pass',
      );

      // Watch query reacts via Drift's table-update tracking; give the
      // stream a moment to fire.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(received, isNotEmpty);
      expect(received.last, hasLength(1));
      expect(received.last.single.producingNodeId, 'live-node');
    });
  });
}
