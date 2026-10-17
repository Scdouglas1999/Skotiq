import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase database;
  late TargetsDao targetsDao;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    targetsDao = TargetsDao(database);
  });

  tearDown(() async {
    await database.close();
  });

  group('TargetsDao.getObservableTargets', () {
    test('filters targets by computed altitude and minAltitude', () async {
      await targetsDao.createTarget(
        TargetsCompanion.insert(
          name: 'North High',
          ra: 2.0,
          dec: 65.0,
          minAltitude: const Value(30.0),
        ),
      );
      await targetsDao.createTarget(
        TargetsCompanion.insert(
          name: 'South Low',
          ra: 10.0,
          dec: -25.0,
          minAltitude: const Value(10.0),
        ),
      );

      final observable = await targetsDao.getObservableTargets(90.0, 0.0);
      final names = observable.map((t) => t.name).toList();

      expect(names, contains('North High'));
      expect(names, isNot(contains('South Low')));
    });

    test('returns observable targets sorted by descending priority', () async {
      await targetsDao.createTarget(
        TargetsCompanion.insert(
          name: 'Low Priority',
          ra: 1.0,
          dec: 60.0,
          minAltitude: const Value(20.0),
          priority: const Value(2),
        ),
      );
      await targetsDao.createTarget(
        TargetsCompanion.insert(
          name: 'High Priority',
          ra: 2.0,
          dec: 70.0,
          minAltitude: const Value(20.0),
          priority: const Value(9),
        ),
      );

      final observable = await targetsDao.getObservableTargets(90.0, 0.0);
      final names = observable.map((t) => t.name).toList();

      expect(names.first, equals('High Priority'));
      expect(names, contains('Low Priority'));
    });
  });
}
