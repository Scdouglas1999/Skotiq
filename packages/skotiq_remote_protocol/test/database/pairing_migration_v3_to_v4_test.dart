import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('pairing DB migration v3 -> v4', () {
    Future<File> createV3Database(Directory dir) async {
      final dbFile = File('${dir.path}/pairing.db');
      final setupDb = PairingDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.addPairedDevice(
          deviceId: 'legacy-phone',
          deviceName: 'Legacy Phone',
          sessionToken: 'legacy-token',
          deviceType: 'mobile',
          expiresAt: DateTime.utc(2030, 1, 1),
        );
        // Recreate the exact v3 shape: all v3 tables remain, but paired
        // devices did not yet carry an authorization-grant column.
        await setupDb.customStatement(
          'ALTER TABLE paired_devices DROP COLUMN auth_grant_spec',
        );
        await setupDb.customStatement('PRAGMA user_version = 3');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    test(
      'preserves pairings and backfills the historical control grant',
      () async {
        final dir = await Directory.systemTemp.createTemp('ns_pairing_v3v4_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });
        final dbFile = await createV3Database(dir);

        final upgraded = PairingDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final device = await upgraded.getPairedDevice('legacy-phone');
          expect(device, isNotNull);
          expect(device!.sessionToken, 'legacy-token');
          expect(device.authGrantSpec, 'control');

          final columns = await upgraded
              .customSelect('PRAGMA table_info(paired_devices)')
              .get();
          expect(
            columns.map((row) => row.data['name']),
            contains('auth_grant_spec'),
          );
        } finally {
          await upgraded.close();
        }
      },
    );
  });
}
