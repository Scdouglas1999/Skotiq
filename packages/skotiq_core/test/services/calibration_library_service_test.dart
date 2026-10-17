import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/calibration_tags_dao.dart';
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/calibration/calibration_library_models.dart';
import 'package:skotiq_core/src/services/calibration/fits_header_reader.dart';
import 'package:skotiq_core/src/services/calibration_library_service.dart';

void main() {
  // Fixed clock so staleness windows are deterministic.
  final now = DateTime.utc(2026, 6, 9, 22);

  late SkotiqDatabase db;
  late DarkLibraryDao darkDao;
  late FlatLibraryDao flatDao;
  late CalibrationTagsDao tagsDao;
  late CalibrationLibraryService service;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    darkDao = DarkLibraryDao(db);
    flatDao = FlatLibraryDao(db);
    tagsDao = CalibrationTagsDao(db);
    service = CalibrationLibraryService(
      db: db,
      flatLibraryDao: flatDao,
      tagsDao: tagsDao,
      // Disable header enrichment in tests: the test fixtures are not real
      // FITS files, and the matcher logic under test doesn't depend on it.
      headerReader: const FitsHeaderReader(),
      now: () => now,
    );
  });

  tearDown(() async => db.close());

  Future<int> insertDark({
    required double exposureTime,
    int gain = 100,
    int offset = 50,
    int binX = 1,
    int binY = 1,
    double? temperature,
    bool master = true,
    DateTime? createdAt,
    String frameType = 'dark',
  }) {
    return darkDao.addEntry(
      DarkLibraryCompanion.insert(
        filePath:
            '/raw/dark_${exposureTime.toInt()}_${gain}_'
            '${DateTime.now().microsecondsSinceEpoch}.fits',
        exposureTime: exposureTime,
        frameType: Value(frameType),
        temperature: Value(temperature),
        gain: Value(gain),
        offset: Value(offset),
        binX: Value(binX),
        binY: Value(binY),
        masterDarkPath: Value(master ? '/master/dark.fits' : null),
        masterFrameCount: Value(master ? 20 : null),
        createdAt: Value(createdAt ?? now),
      ),
    );
  }

  Future<int> insertFlat({
    String filter = 'L',
    int gain = 100,
    int offset = 50,
    int binX = 1,
    int binY = 1,
    double? temperature,
    String? opticalTrainId,
    DateTime? createdAt,
  }) {
    return flatDao.addEntry(
      filePath:
          '/master/flat_${filter}_'
          '${DateTime.now().microsecondsSinceEpoch}.fits',
      filter: filter,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      temperature: temperature,
      opticalTrainId: opticalTrainId,
      masterFrameCount: 25,
      createdAt: createdAt ?? now,
    );
  }

  group('dark matching', () {
    test('requires exact gain/offset/binning', () async {
      await insertDark(exposureTime: 300, gain: 100, offset: 50);

      final wrongGain = await service.match(
        const LightFrameContext(gain: 200, offset: 50, exposureSeconds: 300),
      );
      expect(
        wrongGain.dark,
        isNull,
        reason: 'a dark at gain 100 must not match a gain-200 light',
      );
      expect(wrongGain.warnings, isNotEmpty);

      final wrongOffset = await service.match(
        const LightFrameContext(gain: 100, offset: 99, exposureSeconds: 300),
      );
      expect(wrongOffset.dark, isNull);

      final wrongBin = await service.match(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          binX: 2,
          binY: 2,
        ),
      );
      expect(wrongBin.dark, isNull);

      final exact = await service.match(
        const LightFrameContext(gain: 100, offset: 50, exposureSeconds: 300),
      );
      expect(exact.dark, isNotNull);
      expect(exact.dark!.exposureScaled, isFalse);
      // No staleness/exposure penalty on an exact, fresh dark. (A small
      // penalty applies for missing temperature metadata, which this fixture
      // omits — see the temperature-aware case below for a full-score path.)
      expect(exact.dark!.score, greaterThanOrEqualTo(90));
    });

    test('exact gain/offset/exposure/temp scores a perfect 100', () async {
      await insertDark(
        exposureTime: 300,
        gain: 100,
        offset: 50,
        temperature: -10,
      );

      final match = await service.match(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          temperature: -10,
        ),
      );
      expect(match.dark, isNotNull);
      expect(match.dark!.exposureScaled, isFalse);
      expect(match.dark!.score, 100);
      expect(match.dark!.warnings, isEmpty);
    });

    test('nearest exposure flags scaling with a warning + factor', () async {
      // Only a 120s dark exists; the light wants 300s.
      await insertDark(exposureTime: 120, gain: 100, offset: 50);

      final match = await service.match(
        const LightFrameContext(gain: 100, offset: 50, exposureSeconds: 300),
      );
      expect(match.dark, isNotNull);
      expect(match.dark!.exposureScaled, isTrue);
      expect(match.dark!.exposureScaleFactor, closeTo(300 / 120, 1e-9));
      expect(match.dark!.warnings.any((w) => w.contains('scaled')), isTrue);
      expect(match.dark!.score, lessThan(100));
    });

    test('exposure within tolerance is an exact (non-scaled) match', () async {
      await insertDark(exposureTime: 300.3, gain: 100, offset: 50);

      final match = await service.match(
        const LightFrameContext(gain: 100, offset: 50, exposureSeconds: 300),
      );
      expect(match.dark, isNotNull);
      expect(match.dark!.exposureScaled, isFalse);
    });

    test('temperature delta beyond tolerance produces a warning', () async {
      await insertDark(
        exposureTime: 300,
        gain: 100,
        offset: 50,
        temperature: 10,
      );

      final match = await service.match(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          temperature: -10,
        ),
      );
      expect(match.dark, isNotNull);
      expect(
        match.dark!.warnings.any(
          (w) => w.toLowerCase().contains('temperature'),
        ),
        isTrue,
      );
      expect(match.dark!.score, lessThan(100));
    });

    test('master beats a raw frame of the same parameters', () async {
      await insertDark(exposureTime: 300, gain: 100, offset: 50, master: false);
      await insertDark(exposureTime: 300, gain: 100, offset: 50, master: true);

      final match = await service.match(
        const LightFrameContext(gain: 100, offset: 50, exposureSeconds: 300),
      );
      expect(match.dark, isNotNull);
      expect(match.dark!.record.isMaster, isTrue);
    });

    test('dark older than the staleness window warns', () async {
      await insertDark(
        exposureTime: 300,
        gain: 100,
        offset: 50,
        createdAt: now.subtract(const Duration(days: 120)),
      );

      final match = await service.match(
        const LightFrameContext(gain: 100, offset: 50, exposureSeconds: 300),
      );
      expect(match.dark, isNotNull);
      expect(match.dark!.warnings.any((w) => w.contains('120 days')), isTrue);
    });
  });

  group('bias matching', () {
    test('matches exact gain/offset and is detected as a bias', () async {
      await insertDark(
        exposureTime: 0,
        gain: 100,
        offset: 50,
        frameType: 'bias',
      );

      final match = await service.match(
        const LightFrameContext(gain: 100, offset: 50, exposureSeconds: 300),
      );
      expect(match.bias, isNotNull);
      expect(match.bias!.record.type, CalibrationMasterType.bias);
    });
  });

  group('flat matching', () {
    test('matches by filter and prefers the newest', () async {
      await insertFlat(
        filter: 'L',
        createdAt: now.subtract(const Duration(days: 2)),
      );
      final newerId = await insertFlat(
        filter: 'L',
        createdAt: now.subtract(const Duration(days: 1)),
      );
      await insertFlat(filter: 'R');

      final match = await service.match(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          filter: 'L',
        ),
      );
      expect(match.flat, isNotNull);
      expect(match.flat!.record.filter, 'L');
      expect(
        match.flat!.record.id,
        newerId,
        reason: 'newest qualifying flat wins',
      );
    });

    test('flat older than 7 days warns (stale)', () async {
      await insertFlat(
        filter: 'L',
        createdAt: now.subtract(const Duration(days: 10)),
      );

      final match = await service.match(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          filter: 'L',
        ),
      );
      expect(match.flat, isNotNull);
      expect(match.flat!.warnings.any((w) => w.contains('10 days')), isTrue);
    });

    test('no flat for the requested filter yields a warning', () async {
      await insertFlat(filter: 'L');

      final match = await service.match(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          filter: 'Ha',
        ),
      );
      expect(match.flat, isNull);
      expect(match.warnings.any((w) => w.contains('Ha')), isTrue);
    });

    test('a flat whose filter lives only in its FITS header is matched, not '
        'reported missing while the library list shows it', () async {
      final dir = await Directory.systemTemp.createTemp('cal_flat_header');
      addTearDown(() => dir.delete(recursive: true));
      final flatPath = '${dir.path}/master_flat.fits';
      await File(flatPath).writeAsBytes(const [0]);

      // The DB row carries no filter — only the header names it.
      await flatDao.addEntry(
        filePath: flatPath,
        gain: 100,
        offset: 50,
        binX: 1,
        binY: 1,
        createdAt: now.subtract(const Duration(days: 1)),
      );

      final enriching = CalibrationLibraryService(
        db: db,
        flatLibraryDao: flatDao,
        tagsDao: tagsDao,
        headerReader: _FixedHeaderReader({
          flatPath: {'FILTER': "'Ha'", 'CCD-TEMP': '-10.0'},
        }),
        now: () => now,
      );

      final listed = await enriching.listMasters(
        filter: const CalibrationLibraryFilter(
          type: CalibrationMasterType.flat,
        ),
      );
      expect(listed.single.filter, 'Ha');

      final match = await enriching.match(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          filter: 'Ha',
        ),
      );
      expect(match.flat, isNotNull);
      expect(match.flat!.record.filePath, flatPath);
      expect(
        match.warnings.any((w) => w.contains('No matching master flat')),
        isFalse,
        reason: 'the matcher must not contradict the library list',
      );
    });
  });

  group('unrecorded gain / offset', () {
    test('a light with no recorded gain still matches on the remaining '
        'dimensions and reports gain unverified', () async {
      // The only dark in the library was shot at gain 100. Before the light's
      // unknown gain propagated as null it was compared as 0, so this dark
      // could never match and dark subtraction was silently skipped.
      await insertDark(
        exposureTime: 300,
        gain: 100,
        offset: 50,
        temperature: -10,
      );

      final match = await service.match(
        const LightFrameContext(
          gain: null,
          offset: 50,
          exposureSeconds: 300,
          temperature: -10,
        ),
      );

      expect(match.dark, isNotNull);
      expect(match.dark!.record.gain, 100);
      expect(
        match.dark!.reasons.any((r) => r.contains('gain UNVERIFIED')),
        isTrue,
      );
      expect(
        match.dark!.reasons.any((r) => r.contains('gain 0')),
        isFalse,
        reason: 'an unrecorded gain is never rendered as a value',
      );
      expect(
        match.dark!.warnings.any(
          (w) => w.contains('record no gain') && w.contains('dark'),
        ),
        isTrue,
      );
      expect(
        match.dark!.score,
        lessThan(100),
        reason: 'a pick verified on fewer dimensions is a weaker pick',
      );
    });

    test('an unrecorded gain does not relax the dimensions that ARE '
        'recorded', () async {
      await insertDark(exposureTime: 300, gain: 100, offset: 50);

      final wrongOffset = await service.match(
        const LightFrameContext(gain: null, offset: 99, exposureSeconds: 300),
      );
      expect(wrongOffset.dark, isNull);

      final wrongBin = await service.match(
        const LightFrameContext(
          gain: null,
          offset: 50,
          exposureSeconds: 300,
          binX: 2,
          binY: 2,
        ),
      );
      expect(wrongBin.dark, isNull);
    });

    test('an unrecorded offset is reported on the bias and flat picks '
        'too', () async {
      await insertDark(
        exposureTime: 0,
        gain: 100,
        offset: 50,
        frameType: 'bias',
      );
      await insertFlat(filter: 'L', gain: 100, offset: 50);

      final match = await service.match(
        const LightFrameContext(
          gain: 100,
          offset: null,
          exposureSeconds: 300,
          filter: 'L',
        ),
      );

      expect(match.bias, isNotNull);
      expect(
        match.bias!.warnings.any(
          (w) => w.contains('record no offset') && w.contains('bias'),
        ),
        isTrue,
      );
      expect(match.flat, isNotNull);
      expect(
        match.flat!.warnings.any(
          (w) => w.contains('record no offset') && w.contains('flat'),
        ),
        isTrue,
      );
    });

    test('the set-level miss warning says unrecorded, never gain 0', () async {
      // Nothing in the library at all: both types miss and the warning has to
      // describe the context it failed to satisfy.
      final match = await service.match(
        const LightFrameContext(
          gain: null,
          offset: null,
          exposureSeconds: 300,
          filter: 'L',
        ),
      );

      expect(match.dark, isNull);
      final darkWarning = match.warnings.firstWhere(
        (w) => w.contains('No matching master dark'),
      );
      expect(darkWarning, contains('gain unrecorded'));
      expect(darkWarning, contains('offset unrecorded'));
      expect(darkWarning, isNot(contains('gain 0')));
    });

    test('a fully recorded tuple is unchanged: exact reason, no unverified '
        'warning, full score', () async {
      await insertDark(
        exposureTime: 300,
        gain: 100,
        offset: 50,
        temperature: -10,
      );

      final match = await service.match(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          temperature: -10,
        ),
      );
      expect(match.dark, isNotNull);
      expect(
        match.dark!.reasons,
        contains(
          'Exact gain 100 / offset 50 / bin 1x1 match (required for '
          'darks)',
        ),
      );
      expect(match.dark!.reasons.any((r) => r.contains('UNVERIFIED')), isFalse);
      expect(match.dark!.warnings, isEmpty);
      expect(match.dark!.score, 100);
    });
  });

  group('tags + listing', () {
    test('setTags / setNotes round-trip onto the listed record', () async {
      final id = await insertDark(exposureTime: 300);
      await service.setTags(CalibrationMasterType.dark, id, [
        'keeper',
        ' best ',
      ]);
      await service.setNotes(CalibrationMasterType.dark, id, 'shot under -10C');

      final records = await service.listMasters(enrichFromHeaders: false);
      final record = records.firstWhere((r) => r.id == id);
      expect(record.tags, ['keeper', 'best']);
      expect(record.notes, 'shot under -10C');
    });

    test('listMasters filters by type', () async {
      await insertDark(exposureTime: 300);
      await insertFlat(filter: 'L');

      final flats = await service.listMasters(
        filter: const CalibrationLibraryFilter(
          type: CalibrationMasterType.flat,
        ),
        enrichFromHeaders: false,
      );
      expect(flats, hasLength(1));
      expect(flats.single.type, CalibrationMasterType.flat);
    });
  });

  group('deletion', () {
    test('deleteMaster removes the row and its tags', () async {
      final id = await insertDark(exposureTime: 300);
      await service.setTags(CalibrationMasterType.dark, id, ['x']);

      final removed = await service.deleteMaster(
        CalibrationMasterType.dark,
        id,
      );
      expect(removed, isTrue);

      final records = await service.listMasters(enrichFromHeaders: false);
      expect(records.where((r) => r.id == id), isEmpty);
      expect(
        await tagsDao.getForMaster(CalibrationMasterType.dark, id),
        isNull,
      );
    });

    test('deleting a non-existent master returns false', () async {
      expect(
        await service.deleteMaster(CalibrationMasterType.dark, 9999),
        isFalse,
      );
    });
  });
}

/// A [FitsHeaderReader] that serves canned primary headers by path, so the
/// enrichment pass can be exercised without writing real FITS files.
class _FixedHeaderReader implements FitsHeaderReader {
  const _FixedHeaderReader(this._byPath);

  final Map<String, Map<String, String>> _byPath;

  @override
  Future<Map<String, String>> readPrimaryHeader(String path) async =>
      _byPath[path] ?? const {};
}
