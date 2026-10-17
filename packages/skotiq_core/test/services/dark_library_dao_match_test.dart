import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('DarkLibraryDao.findBestMatch — tolerance unification', () {
    late SkotiqDatabase database;
    late DarkLibraryDao dao;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      dao = DarkLibraryDao(database);
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'regression: an exact 60.0s dark MUST match a 60.0s light frame request '
      'with the default tolerances',
      () async {
        // The DAO and the coverage UI share the ±0.5s default, so the
        // exact-match case the UI reports as covered must match here too. A
        // tolerance near zero returns null for equal exposures depending on
        // floating-point representation.
        await dao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/dark_60s.fits',
            exposureTime: 60.0,
            frameType: const Value('dark'),
            gain: const Value(100),
            offset: const Value(10),
            binX: const Value(1),
            binY: const Value(1),
            temperature: const Value(-10),
          ),
        );

        final match = await dao.findBestMatch(
          exposureTime: 60.0,
          gain: 100,
          offset: 10,
          binX: 1,
          binY: 1,
          temperature: -10,
        );

        expect(
          match,
          isNotNull,
          reason:
              'the 60.0s dark MUST be returned for a 60.0s request — '
              'this is the failure mode the audit identified',
        );
        expect(match!.filePath, '/tmp/dark_60s.fits');
      },
    );

    test('matches darks within the default ±0.5s exposure tolerance', () async {
      // 60.0s requested, 60.4s on disk → within ±0.5s.
      await dao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/tmp/dark_604.fits',
          exposureTime: 60.4,
          frameType: const Value('dark'),
          gain: const Value(100),
          offset: const Value(10),
          binX: const Value(1),
          binY: const Value(1),
          temperature: const Value(-10),
        ),
      );

      final match = await dao.findBestMatch(
        exposureTime: 60.0,
        gain: 100,
        offset: 10,
        binX: 1,
        binY: 1,
        temperature: -10,
      );

      expect(match?.filePath, '/tmp/dark_604.fits');
    });

    test(
      'rejects darks outside the default ±0.5s exposure tolerance',
      () async {
        // 60.0s requested, 61.0s on disk → outside ±0.5s.
        await dao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/dark_61s.fits',
            exposureTime: 61.0,
            frameType: const Value('dark'),
            gain: const Value(100),
            offset: const Value(10),
            binX: const Value(1),
            binY: const Value(1),
            temperature: const Value(-10),
          ),
        );

        final match = await dao.findBestMatch(
          exposureTime: 60.0,
          gain: 100,
          offset: 10,
          binX: 1,
          binY: 1,
          temperature: -10,
        );

        expect(match, isNull);
      },
    );

    test(
      'caller-supplied wider tolerances let an otherwise-rejected dark match',
      () async {
        await dao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/dark_61s.fits',
            exposureTime: 61.0,
            frameType: const Value('dark'),
            gain: const Value(100),
            offset: const Value(10),
            binX: const Value(1),
            binY: const Value(1),
            temperature: const Value(-10),
          ),
        );

        final match = await dao.findBestMatch(
          exposureTime: 60.0,
          gain: 100,
          offset: 10,
          binX: 1,
          binY: 1,
          temperature: -10,
          tolerances: const DarkLibraryMatchTolerances(
            exposureSecs: 2.0,
            temperatureC: 1.0,
          ),
        );

        expect(match?.filePath, '/tmp/dark_61s.fits');
      },
    );

    test(
      'temperature outside default ±1.0°C tolerance disqualifies the match',
      () async {
        await dao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/dark_warm.fits',
            exposureTime: 60.0,
            frameType: const Value('dark'),
            gain: const Value(100),
            offset: const Value(10),
            binX: const Value(1),
            binY: const Value(1),
            // 1.5°C warmer than the request → outside ±1.0°C
            temperature: const Value(-8.5),
          ),
        );

        final match = await dao.findBestMatch(
          exposureTime: 60.0,
          gain: 100,
          offset: 10,
          binX: 1,
          binY: 1,
          temperature: -10,
        );

        expect(match, isNull);
      },
    );

    test('getMatchingFrames uses the same exposure tolerance', () async {
      // Two raw darks: one within ±0.5s, one outside.
      await dao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/tmp/dark_60.fits',
          exposureTime: 60.0,
          frameType: const Value('dark'),
          gain: const Value(100),
          offset: const Value(10),
          binX: const Value(1),
          binY: const Value(1),
        ),
      );
      await dao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/tmp/dark_604.fits',
          exposureTime: 60.4,
          frameType: const Value('dark'),
          gain: const Value(100),
          offset: const Value(10),
          binX: const Value(1),
          binY: const Value(1),
        ),
      );
      await dao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/tmp/dark_61.fits',
          exposureTime: 61.0,
          frameType: const Value('dark'),
          gain: const Value(100),
          offset: const Value(10),
          binX: const Value(1),
          binY: const Value(1),
        ),
      );

      final frames = await dao.getMatchingFrames(
        exposureTime: 60.0,
        gain: 100,
        offset: 10,
        binX: 1,
        binY: 1,
      );

      final paths = frames.map((f) => f.filePath).toSet();
      expect(paths, {'/tmp/dark_60.fits', '/tmp/dark_604.fits'});
      expect(paths, isNot(contains('/tmp/dark_61.fits')));
    });

    test(
      'exact administrative groups include masters but not nearby exposure',
      () async {
        await dao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/dark_60.fits',
            exposureTime: 60.0,
            frameType: const Value('dark'),
            gain: const Value(100),
            binX: const Value(1),
            binY: const Value(1),
          ),
        );
        await dao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/master_60_source.fits',
            exposureTime: 60.0,
            frameType: const Value('dark'),
            gain: const Value(100),
            binX: const Value(1),
            binY: const Value(1),
            masterDarkPath: const Value('/tmp/master_60.fits'),
          ),
        );
        await dao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/dark_604.fits',
            exposureTime: 60.4,
            frameType: const Value('dark'),
            gain: const Value(100),
            binX: const Value(1),
            binY: const Value(1),
          ),
        );
        await dao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/dark_60_offset20.fits',
            exposureTime: 60.0,
            frameType: const Value('dark'),
            gain: const Value(100),
            offset: const Value(20),
            binX: const Value(1),
            binY: const Value(1),
          ),
        );

        final entries = await dao.getEntriesForGroup(
          const DarkGroupKey(
            frameType: 'dark',
            exposureTime: 60.0,
            gain: 100,
            offset: 0,
            binX: 1,
            binY: 1,
          ),
        );

        expect(entries.map((entry) => entry.filePath).toSet(), {
          '/tmp/dark_60.fits',
          '/tmp/master_60_source.fits',
        });

        final groups = await dao.getDistinctGroups();
        expect(
          groups.where((group) => group.exposureTime == 60.0),
          hasLength(2),
          reason: 'different camera offsets require different master groups',
        );
      },
    );
  });
}
