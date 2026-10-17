// Paired devices are long-lived remote credentials, so the pairing store must
// honour SKOTIQ_DATABASE_DIR like every other store: resolving straight to
// getApplicationDocumentsDirectory()/Skotiq/pairing.db means a scratch
// profile with its own empty database still trusts every device the real
// install ever paired, and moving the data directory leaves the credentials
// behind.
//
// These tests pin the resolver against the same override skotiq.db honours,
// and the one-time carry-forward that keeps an existing headless daemon's
// pairings.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pairing_location_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('the configured data directory owns pairing.db', () async {
    final dataDir = Directory(p.join(root.path, 'daemon-state'))
      ..createSync(recursive: true);
    final docs = Directory(p.join(root.path, 'Documents'))
      ..createSync(recursive: true);

    final file = await resolvePairingDatabaseFile(
      environment: {'SKOTIQ_DATABASE_DIR': dataDir.path},
      documentsDirectoryProvider: () async => docs,
    );

    expect(file.path, p.join(dataDir.path, 'pairing.db'));
  });

  test('without an override the store stays in Documents/Skotiq', () async {
    final docs = Directory(p.join(root.path, 'Documents'))
      ..createSync(recursive: true);

    final file = await resolvePairingDatabaseFile(
      environment: const {},
      documentsDirectoryProvider: () async => docs,
    );

    expect(file.path, p.join(docs.path, 'Skotiq', 'pairing.db'));
  });

  test(
    'an empty override is ignored rather than resolving to a bare filename',
    () async {
      final docs = Directory(p.join(root.path, 'Documents'))
        ..createSync(recursive: true);

      final file = await resolvePairingDatabaseFile(
        environment: const {'SKOTIQ_DATABASE_DIR': '   '},
        documentsDirectoryProvider: () async => docs,
      );

      expect(file.path, p.join(docs.path, 'Skotiq', 'pairing.db'));
    },
  );

  test(
    'a fresh data directory does NOT inherit the machine-wide pairings',
    () async {
      final docs = Directory(p.join(root.path, 'Documents'))
        ..createSync(recursive: true);
      final legacyDir = Directory(p.join(docs.path, 'Skotiq'))
        ..createSync(recursive: true);
      File(
        p.join(legacyDir.path, 'pairing.db'),
      ).writeAsStringSync('legacy-main');

      final target = File(p.join(root.path, 'daemon-state', 'pairing.db'));
      await target.parent.create(recursive: true);

      await migrateLegacyPairingStore(
        target,
        environment: const {},
        documentsDirectoryProvider: () async => docs,
      );

      expect(target.existsSync(), isFalse);
    },
  );

  test(
    'the opt-in carries an existing Documents store forward, with its WAL',
    () async {
      final docs = Directory(p.join(root.path, 'Documents'))
        ..createSync(recursive: true);
      final legacyDir = Directory(p.join(docs.path, 'Skotiq'))
        ..createSync(recursive: true);
      File(
        p.join(legacyDir.path, 'pairing.db'),
      ).writeAsStringSync('legacy-main');
      File(p.join(legacyDir.path, 'pairing.db-wal')).writeAsStringSync('wal');

      final target = File(p.join(root.path, 'daemon-state', 'pairing.db'));
      await target.parent.create(recursive: true);

      await migrateLegacyPairingStore(
        target,
        environment: const {importLegacyPairingsEnv: '1'},
        documentsDirectoryProvider: () async => docs,
      );

      expect(target.readAsStringSync(), 'legacy-main');
      expect(File('${target.path}-wal').readAsStringSync(), 'wal');
    },
  );

  test(
    'carry-forward never overwrites a store the new location already has',
    () async {
      final docs = Directory(p.join(root.path, 'Documents'))
        ..createSync(recursive: true);
      final legacyDir = Directory(p.join(docs.path, 'Skotiq'))
        ..createSync(recursive: true);
      File(
        p.join(legacyDir.path, 'pairing.db'),
      ).writeAsStringSync('legacy-main');

      final target = File(p.join(root.path, 'daemon-state', 'pairing.db'));
      await target.parent.create(recursive: true);
      target.writeAsStringSync('live-daemon-store');

      await migrateLegacyPairingStore(
        target,
        environment: const {importLegacyPairingsEnv: '1'},
        documentsDirectoryProvider: () async => docs,
      );

      expect(target.readAsStringSync(), 'live-daemon-store');
    },
  );

  test(
    'carry-forward is a no-op when the resolved path IS the legacy path',
    () async {
      final docs = Directory(p.join(root.path, 'Documents'))
        ..createSync(recursive: true);
      final legacyDir = Directory(p.join(docs.path, 'Skotiq'))
        ..createSync(recursive: true);
      final legacy = File(p.join(legacyDir.path, 'pairing.db'))
        ..writeAsStringSync('legacy-main');

      await migrateLegacyPairingStore(
        legacy,
        environment: const {importLegacyPairingsEnv: '1'},
        documentsDirectoryProvider: () async => docs,
      );

      expect(legacy.readAsStringSync(), 'legacy-main');
    },
  );
}
