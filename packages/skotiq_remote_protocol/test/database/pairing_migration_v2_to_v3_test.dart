// Stepped migration test for the pairing DB v2 -> v3 step (Phase D, cellular
// push): `device_push_tokens` + `device_push_prefs` are added as two NEW
// tables via `onUpgrade`'s `m.createTable(...)` branch. The bump is purely
// additive — an existing v2 deployment (paired-device rows already on disk)
// must gain the two tables WITHOUT losing a single paired device.
//
// Pattern mirrors the skotiq_core migration tests
// (migration_v38_to_v39_test.dart):
//   1. Open a fresh on-disk DB at the current version via onCreate.
//   2. DROP both Phase-D tables and the later v4 grant column, then rewind
//      PRAGMA user_version to 2 so the DB has a genuine v2 shape.
//   3. Reopen — triggers the stepped onUpgrade(2, current), including
//      `m.createTable(devicePushTokens)` + `m.createTable(devicePushPrefs)`.
//   4. Assert both tables now exist, the seeded paired-device row survived, and
//      the push accessors the /api/push/* endpoints sit on work end to end.
//
// On-disk (not in-memory) because `PRAGMA user_version` must persist across the
// close/reopen that drives the migration.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('pairing DB stepped migration onUpgrade v2 -> v3 (Phase D push)', () {
    /// Creates a fresh on-disk DB at the current schema, then removes every
    /// post-v2 addition and rewinds `PRAGMA user_version = 2`. Seeds one paired
    /// device so the test proves the stepped additive upgrades preserve rows.
    Future<File> createV2Database(Directory dir) async {
      final dbFile = File('${dir.path}/pairing.db');
      final setupDb = PairingDatabase.forTesting(NativeDatabase(dbFile));
      try {
        // A real paired device must already be on disk before the upgrade.
        await setupDb.addPairedDevice(
          deviceId: 'legacy-phone',
          deviceName: 'Pre-Phase-D Phone',
          sessionToken: 'legacy-token',
          deviceType: 'mobile',
          expiresAt: DateTime.utc(2030, 1, 1),
        );
        // Reduce to the pre-Phase-D (v2) shape: the push tables did not exist.
        await setupDb.customStatement('DROP TABLE device_push_tokens');
        await setupDb.customStatement('DROP TABLE device_push_prefs');
        await setupDb.customStatement(
          'ALTER TABLE paired_devices DROP COLUMN auth_grant_spec',
        );
        await setupDb.customStatement('PRAGMA user_version = 2');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    Future<Directory> tempDir(String suffix) async {
      final dir = await Directory.systemTemp.createTemp(
        'ns_pairing_v2v3_$suffix',
      );
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      return dir;
    }

    test('creates device_push_tokens + device_push_prefs on upgrade', () async {
      final dbFile = await createV2Database(await tempDir('tables'));

      final upgraded = PairingDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final tables = await upgraded
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get();
        final names = tables.map((r) => r.data['name'] as String).toSet();
        expect(
          names,
          containsAll(<String>['device_push_tokens', 'device_push_prefs']),
          reason: 'onUpgrade(2,3) must create both Phase-D tables',
        );
      } finally {
        await upgraded.close();
      }
    });

    test('the existing paired-device row survives the additive bump', () async {
      final dbFile = await createV2Database(await tempDir('preserve'));

      final upgraded = PairingDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final device = await upgraded.getPairedDevice('legacy-phone');
        expect(
          device,
          isNotNull,
          reason:
              'An additive table-add migration must not touch existing '
              'paired-device rows. If this fails the migration is destroying '
              'pairing state on upgrade.',
        );
        expect(device!.deviceName, 'Pre-Phase-D Phone');
        expect(device.sessionToken, 'legacy-token');
      } finally {
        await upgraded.close();
      }
    });

    test(
      'push accessors work after the upgrade (token upsert + prefs)',
      () async {
        final dbFile = await createV2Database(await tempDir('accessors'));

        final upgraded = PairingDatabase.forTesting(NativeDatabase(dbFile));
        try {
          // The /api/push/register-token path: upsert a token for the device
          // that pre-existed the migration.
          await upgraded.upsertPushToken(
            deviceId: 'legacy-phone',
            platform: 'fcm',
            token: 'post-upgrade-token',
          );
          final tokens = await upgraded.getPushTokensByPlatform('fcm');
          expect(tokens, hasLength(1));
          expect(tokens.single.deviceId, 'legacy-phone');
          expect(tokens.single.token, 'post-upgrade-token');

          // The /api/push/preferences PUT path: round-trips through the new table.
          await upgraded.upsertPushPrefs(
            deviceId: 'legacy-phone',
            enabled: true,
            muteSequenceFailed: false,
            muteWeatherUnsafe: true,
            muteGuidingLost: false,
            muteAutofocusFailed: false,
            muteEquipmentDisconnected: false,
          );
          final prefs = await upgraded.getPushPrefs('legacy-phone');
          expect(prefs, isNotNull);
          expect(prefs!.muteWeatherUnsafe, isTrue);
          expect(prefs.enabled, isTrue);
        } finally {
          await upgraded.close();
        }
      },
    );
  });
}
