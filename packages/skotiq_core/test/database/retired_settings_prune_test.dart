import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A retired settings key keeps its seeded value forever: nothing writes it,
/// but `BackupService._exportSettings` dumps the whole `app_settings` table
/// into every `.nsbackup`, so the stale row is exported as if it were
/// configuration. `auto_save_sequences` (seeded `'true'`) contradicts
/// `autosave.sequence_enabled` (default `false`), the key the toggle shows and
/// `AutoSaveService` obeys.
///
/// Dropping a key from the seed map only helps profiles that do not exist yet,
/// so the row is removed when the database is opened.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_retired_settings_');
    dbFile = File('${tempDir.path}/skotiq.db');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('a fresh profile is never seeded with the retired key', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);
    final all = await db.settingsDao.getAllSettings();

    expect(all.containsKey('auto_save_sequences'), isFalse);
    // The key that actually drives sequence auto-save is untouched.
    expect(all.containsKey('autosave.sequence_enabled'), isFalse);
  });

  test(
    'a profile written by an older build has the row removed on open',
    () async {
      // An existing profile carrying the retired seed row.
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await first.settingsDao.setSetting('auto_save_sequences', 'true');
      await first.settingsDao.setSetting('autosave.sequence_enabled', 'false');
      expect(
        await first.settingsDao.getSetting('auto_save_sequences'),
        'true',
        reason: 'precondition: the stale row is really there',
      );
      await first.close();

      // Next launch.
      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      final all = await second.settingsDao.getAllSettings();

      expect(all.containsKey('auto_save_sequences'), isFalse);
      // Only the retired key goes: the one the app obeys survives untouched.
      expect(all['autosave.sequence_enabled'], 'false');
    },
  );

  // `cooling_behavior` shipped seeded 'On Connect' with no UI, no setter
  // caller and no reader that acted on it. Whether the cooler runs on connect
  // is a per-profile decision (`equipment_profiles.cool_on_connect`), so every
  // settings snapshot, .nsbackup and /api/settings payload announced automatic
  // cooling that nothing performed.
  test('cooling_behavior is not seeded into a fresh profile', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);
    final all = await db.settingsDao.getAllSettings();

    expect(all.containsKey('cooling_behavior'), isFalse);
  });

  test('cooling_behavior left by an older build is removed on open', () async {
    final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    await first.settingsDao.setSetting('cooling_behavior', 'On Connect');
    expect(
      await first.settingsDao.getSetting('cooling_behavior'),
      'On Connect',
      reason: 'precondition: the stale row is really there',
    );
    await first.close();

    final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final all = await second.settingsDao.getAllSettings();

    expect(all.containsKey('cooling_behavior'), isFalse);
  });
}
