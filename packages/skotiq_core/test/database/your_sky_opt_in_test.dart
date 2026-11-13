// Your Sky is opt-in: a fresh profile has it off, a profile that only had it
// on through the old default is turned off once (keeping its data and owing
// the user a notice), and a choice made after that is never undone.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

void main() {
  late Directory dir;
  late File dbFile;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('your-sky-opt-in-');
    dbFile = File(p.join(dir.path, 'skotiq.db'));
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<Map<String, String?>> open(
    Future<void> Function(SkotiqDatabase db)? before,
  ) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final dao = SettingsDao(db);
      await before?.call(db);
      return {
        'atlas': await dao.getSetting('science.feature.sky_atlas'),
        'notice': await dao.getSetting(skyAtlasOffNoticeKey),
        'marker': await dao.getSetting(skyAtlasOptInMigratedKey),
      };
    } finally {
      await db.close();
    }
  }

  test('a fresh profile has Your sky off and owes no notice', () async {
    final s = await open(null);
    expect(s['atlas'], 'false');
    expect(s['notice'], isNull);
    expect(s['marker'], 'true');
  });

  test('an upgraded profile on through the old default is turned off once, '
      'with a notice', () async {
    // Simulate a profile from before the rule: seeded on, never migrated.
    await open((db) async {
      await db.customStatement(
        "UPDATE app_settings SET value = 'true' "
        "WHERE key = 'science.feature.sky_atlas'",
      );
      await db.customStatement('DELETE FROM app_settings WHERE key = ?', [
        skyAtlasOptInMigratedKey,
      ]);
    });

    final after = await open(null);
    expect(after['atlas'], 'false');
    expect(after['notice'], 'pending');
    expect(after['marker'], 'true');
  });

  test(
    'turning it on after the rule ran is kept on every later open',
    () async {
      await open(
        (db) => SettingsDao(db).setSetting('science.feature.sky_atlas', 'true'),
      );
      final later = await open(null);
      expect(later['atlas'], 'true');
      expect(later['notice'], isNull);
    },
  );

  test('science settings read off when nothing is stored', () {
    expect(const ScienceSettings().skyAtlasEnabled, isFalse);
  });

  test('a pending notice with no data on disk settles itself', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await SettingsDao(db).setSetting(skyAtlasOffNoticeKey, 'pending');
    final root = await Directory.systemTemp.createTemp('atlas-empty-');
    addTearDown(() => root.delete(recursive: true));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        skyAtlasServiceProvider.overrideWith(
          (ref) => SkyAtlasService(
            dao: SkyAtlasDao(db),
            seam: const BridgeSkyAtlasSeam(),
            logger: LoggingService(),
            atlasRootResolver: () async => root.path,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(skyAtlasOffNoticeProvider.future), isNull);
    expect(await SettingsDao(db).getSetting(skyAtlasOffNoticeKey), 'shown');
  });

  test('a pending notice reports the data kept on disk', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await SettingsDao(db).setSetting(skyAtlasOffNoticeKey, 'pending');
    final root = await Directory.systemTemp.createTemp('atlas-kept-');
    addTearDown(() => root.delete(recursive: true));
    await File(p.join(root.path, 'tiles', '9', '1.skt'))
        .create(recursive: true)
        .then((f) => f.writeAsBytes(List<int>.filled(2048, 1)));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        skyAtlasServiceProvider.overrideWith(
          (ref) => SkyAtlasService(
            dao: SkyAtlasDao(db),
            seam: const BridgeSkyAtlasSeam(),
            logger: LoggingService(),
            atlasRootResolver: () async => root.path,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(skyAtlasOffNoticeProvider.future), 2048);
    expect(await SettingsDao(db).getSetting(skyAtlasOffNoticeKey), 'pending');
  });
}
