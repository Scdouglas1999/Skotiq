// Grading became relative by default (owner, 2026-11-16). A profile that
// holds the old absolute limits only because they were the defaults has them
// turned off once; a value the user chose is kept, and a choice made after
// the rule ran is never undone.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/database.dart';

void main() {
  late Directory dir;
  late File dbFile;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('grading-relative-');
    dbFile = File(p.join(dir.path, 'skotiq.db'));
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  const keys = [
    'image_grading_hfr_threshold_px',
    'image_grading_eccentricity_threshold',
    'image_grading_star_count_min',
  ];
  const marker = 'image_grading.relative_defaults_migrated';

  Future<Map<String, String?>> open(
    Future<void> Function(SkotiqDatabase db)? before,
  ) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final dao = SettingsDao(db);
      await before?.call(db);
      return {for (final key in keys) key: await dao.getSetting(key)};
    } finally {
      await db.close();
    }
  }

  /// A profile from before the rule: these rows stored, never migrated.
  Future<void> olderProfile(Map<String, String> rows) => open((db) async {
    final dao = SettingsDao(db);
    for (final MapEntry(:key, :value) in rows.entries) {
      await dao.setSetting(key, value);
    }
    await db.customStatement('DELETE FROM app_settings WHERE key = ?', [
      marker,
    ]);
  });

  test('the old absolute defaults are turned off', () async {
    await olderProfile({
      'image_grading_hfr_threshold_px': '3.5',
      'image_grading_eccentricity_threshold': '0.8',
      'image_grading_star_count_min': '10',
    });
    final after = await open(null);
    expect(after['image_grading_hfr_threshold_px'], 'null');
    expect(after['image_grading_eccentricity_threshold'], 'null');
    expect(after['image_grading_star_count_min'], 'null');
  });

  test('a limit the user chose is kept', () async {
    await olderProfile({
      'image_grading_hfr_threshold_px': '4.2',
      'image_grading_eccentricity_threshold': '0.75',
      'image_grading_star_count_min': '25',
    });
    final after = await open(null);
    expect(after['image_grading_hfr_threshold_px'], '4.2');
    expect(after['image_grading_eccentricity_threshold'], '0.75');
    expect(after['image_grading_star_count_min'], '25');
  });

  test('the old default set again after the rule ran is kept', () async {
    await open(null);
    await open(
      (db) =>
          SettingsDao(db).setSetting('image_grading_hfr_threshold_px', '3.5'),
    );
    expect((await open(null))['image_grading_hfr_threshold_px'], '3.5');
  });
}
