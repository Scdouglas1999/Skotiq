// Cloud backup/sync — SyncService tests over a fake in-memory SyncTarget.
//
// Follows the backup_service_extended_test.dart pattern: real
// BackupService over an in-memory drift database, real SettingsDao,
// keyring faked with InMemorySecureKeyValueStore. The remote side is an
// in-memory SyncTarget so we can assert exactly which files were
// uploaded/pruned and corrupt them at will.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Test-only LoggingService that skips native init (same pattern as
/// backup_service_extended_test.dart).
LoggingService _testLogger(Directory tempDir) {
  return LoggingService(
    applicationSupportDirectoryProvider: () async => tempDir,
    nativeInitWithLogging: ({String? logDirectory}) {},
    nativeInit: () {},
    currentLogFileProvider: () => null,
  );
}

/// In-memory [SyncTarget]: a flat map of path -> bytes plus a directory
/// set. Records uploads so prune behaviour can be asserted.
class InMemorySyncTarget implements SyncTarget {
  final Map<String, List<int>> files = {};
  final Set<String> dirs = {};
  final List<String> uploadedPaths = [];
  final List<String> deletedPaths = [];

  @override
  Future<void> ensureDirectory(String path) async {
    var prefix = '';
    for (final segment in path.split('/').where((s) => s.isNotEmpty)) {
      prefix = prefix.isEmpty ? segment : '$prefix/$segment';
      dirs.add(prefix);
    }
  }

  @override
  Future<void> uploadFile(String path, List<int> bytes) async {
    files[path] = List.of(bytes);
    uploadedPaths.add(path);
  }

  @override
  Future<List<int>> downloadFile(String path) async {
    final bytes = files[path];
    if (bytes == null) {
      throw SyncTargetException(
        'not found: $path',
        kind: SyncTargetErrorKind.notFound,
        statusCode: 404,
      );
    }
    return bytes;
  }

  @override
  Future<void> deleteFile(String path) async {
    files.remove(path);
    deletedPaths.add(path);
  }

  @override
  Future<List<SyncRemoteEntry>> listDirectory(String path) async {
    if (!dirs.contains(path)) {
      throw SyncTargetException(
        'not found: $path',
        kind: SyncTargetErrorKind.notFound,
        statusCode: 404,
      );
    }
    final prefix = '$path/';
    final names = <String, bool>{}; // name -> isDirectory
    for (final dir in dirs) {
      if (dir.startsWith(prefix)) {
        names[dir.substring(prefix.length).split('/').first] = true;
      }
    }
    for (final file in files.keys) {
      if (file.startsWith(prefix) &&
          !file.substring(prefix.length).contains('/')) {
        names[file.substring(prefix.length)] = false;
      }
    }
    return [
      for (final entry in names.entries)
        SyncRemoteEntry(
          name: entry.key,
          isDirectory: entry.value,
          sizeBytes: entry.value ? null : files['$prefix${entry.key}']!.length,
        ),
    ];
  }

  @override
  Future<void> testConnection() async {}
}

String _xmlEscape(String v) =>
    v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// An in-memory S3 object store fronted by a [MockClient], answering the
/// PUT / GET / DELETE / list-objects-v2 calls [S3SyncTarget] makes (path
/// style). Lets the real SigV4 signing + XML parsing run end-to-end with no
/// network. The backing [objects] map is shared across every target the
/// factory builds, so push-then-pull sees the same state.
class InMemoryS3 {
  InMemoryS3({required this.bucket});

  final String bucket;
  final Map<String, List<int>> objects = {};

  MockClient client() => MockClient((request) async {
    final segments = request.url.pathSegments;
    if (segments.isEmpty || segments.first != bucket) {
      return http.Response('NoSuchBucket', 404);
    }
    final key = segments.skip(1).join('/');
    final qp = request.url.queryParameters;
    switch (request.method) {
      case 'PUT':
        objects[key] = request.bodyBytes;
        return http.Response('', 200);
      case 'GET':
        if (qp['list-type'] == '2') {
          return http.Response(_listXml(qp), 200);
        }
        final bytes = objects[key];
        if (bytes == null) return http.Response('NoSuchKey', 404);
        return http.Response.bytes(bytes, 200);
      case 'DELETE':
        objects.remove(key);
        return http.Response('', 204);
      default:
        return http.Response('Method Not Allowed', 405);
    }
  });

  String _listXml(Map<String, String> qp) {
    if (int.tryParse(qp['max-keys'] ?? '') == 0) {
      return '<?xml version="1.0"?><ListBucketResult>'
          '<IsTruncated>false</IsTruncated></ListBucketResult>';
    }
    final prefix = qp['prefix'] ?? '';
    final delimiter = qp['delimiter'];
    final contents = <String>[];
    final commonPrefixes = <String>{};
    for (final entry in objects.entries) {
      final k = entry.key;
      if (!k.startsWith(prefix)) continue;
      final rest = k.substring(prefix.length);
      if (delimiter != null &&
          delimiter.isNotEmpty &&
          rest.contains(delimiter)) {
        commonPrefixes.add(
          prefix + rest.substring(0, rest.indexOf(delimiter) + 1),
        );
      } else {
        contents.add(
          '<Contents><Key>${_xmlEscape(k)}</Key>'
          '<Size>${entry.value.length}</Size>'
          '<LastModified>2026-06-01T00:00:00.000Z</LastModified></Contents>',
        );
      }
    }
    final cps = commonPrefixes
        .map(
          (p) =>
              '<CommonPrefixes><Prefix>${_xmlEscape(p)}</Prefix>'
              '</CommonPrefixes>',
        )
        .join();
    return '<?xml version="1.0"?><ListBucketResult>'
        '<IsTruncated>false</IsTruncated>'
        '${contents.join()}$cps</ListBucketResult>';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncManifest.withBundle', () {
    SyncBundleInfo bundle(String file, DateTime createdAt) => SyncBundleInfo(
      file: file,
      sha256: 'h-$file',
      sizeBytes: 1,
      createdAt: createdAt,
    );

    test('prepends newest and trims to retainCount, returning pruned', () {
      final t0 = DateTime.utc(2026, 6, 1);
      final manifest = SyncManifest(
        machine: 'm',
        appVersion: 'v',
        updatedAt: t0,
        bundles: [
          bundle('b3', DateTime.utc(2026, 6, 3)),
          bundle('b2', DateTime.utc(2026, 6, 2)),
          bundle('b1', DateTime.utc(2026, 6, 1)),
        ],
      );

      final (updated, pruned) = manifest.withBundle(
        bundle('b4', DateTime.utc(2026, 6, 4)),
        retainCount: 2,
        now: DateTime.utc(2026, 6, 4),
      );

      expect(updated.bundles.map((b) => b.file), ['b4', 'b3']);
      expect(pruned.map((b) => b.file), ['b2', 'b1']);
    });

    test('retainCount below 1 still keeps the newest bundle', () {
      final manifest = SyncManifest(
        machine: 'm',
        appVersion: 'v',
        updatedAt: DateTime.utc(2026),
        bundles: const [],
      );
      final (updated, pruned) = manifest.withBundle(
        bundle('only', DateTime.utc(2026)),
        retainCount: 0,
        now: DateTime.utc(2026),
      );
      expect(updated.bundles, hasLength(1));
      expect(pruned, isEmpty);
    });

    test('round-trips through JSON', () {
      final manifest = SyncManifest(
        machine: 'laptop',
        appVersion: '2.6.0',
        updatedAt: DateTime.utc(2026, 6, 9, 1, 2, 3),
        bundles: [bundle('b1', DateTime.utc(2026, 6, 8))],
      );
      final decoded = SyncManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.machine, 'laptop');
      expect(decoded.appVersion, '2.6.0');
      expect(decoded.bundles.single.file, 'b1');
      expect(decoded.bundles.single.sha256, 'h-b1');
    });
  });

  group('SyncService', () {
    late SkotiqDatabase db;
    late Directory tempDir;
    late LoggingService logger;
    late InMemorySyncTarget remote;

    setUp(() async {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      tempDir = await Directory.systemTemp.createTemp('ns_cloud_sync_test_');
      logger = _testLogger(tempDir);
      remote = InMemorySyncTarget();
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    SyncService serviceFor(
      SkotiqDatabase database, {
      int retainCount = kSyncDefaultRetainCount,
      bool autoPush = false,
    }) {
      final dao = SettingsDao(database);
      final service = SyncService(
        backupService: BackupService(
          database: database,
          sequenceRepository: SequenceRepository(database.sequencesDao),
          logger: logger,
          appVersion: '5.0.0-test',
        ),
        settingsDao: dao,
        secretsStore: SecretsStore(InMemorySecureKeyValueStore()),
        logger: logger,
        targetFactory: (config, password) => remote,
        downloadDirectoryProvider: () async => tempDir,
      );
      return service;
    }

    Future<void> configure(
      SkotiqDatabase database, {
      int retainCount = kSyncDefaultRetainCount,
      bool autoPush = false,
    }) async {
      await SettingsDao(database).setSettings({
        SyncSettingsKeys.serverUrl: 'https://cloud.example.com/dav/',
        SyncSettingsKeys.username: 'astro',
        SyncSettingsKeys.machineName: 'test-machine',
        SyncSettingsKeys.autoPush: autoPush.toString(),
        SyncSettingsKeys.retainCount: retainCount.toString(),
      });
    }

    test('pushNow uploads bundle + manifest with correct sha256', () async {
      await configure(db);
      final service = serviceFor(db);

      final result = await service.pushNow();

      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.remotePath, startsWith('skotiq-sync/test-machine/'));
      expect(result.remotePath, endsWith('.nsbak'));

      final manifestBytes =
          remote.files['skotiq-sync/test-machine/manifest.json'];
      expect(manifestBytes, isNotNull);
      final manifest = SyncManifest.fromJson(
        jsonDecode(utf8.decode(manifestBytes!)) as Map<String, dynamic>,
      );
      expect(manifest.machine, 'test-machine');
      expect(manifest.appVersion, '5.0.0-test');
      expect(manifest.bundles, hasLength(1));

      final bundleBytes = remote.files[result.remotePath!];
      expect(bundleBytes, isNotNull);
      expect(
        manifest.bundles.single.sha256,
        sha256.convert(bundleBytes!).toString(),
      );
      expect(manifest.bundles.single.sizeBytes, bundleBytes.length);

      // State recorded for the settings UI / status endpoint.
      final status = await service.status();
      expect(status.lastPushAt, isNotNull);
      expect(status.lastError, isNull);
    });

    test('pushNow prunes bundles beyond retainCount', () async {
      await configure(db, retainCount: 2);
      final service = serviceFor(db);

      for (var i = 0; i < 3; i++) {
        final result = await service.pushNow();
        expect(result.success, isTrue, reason: result.errorMessage);
        // The bundle filename derives from the wall clock; make sure two
        // pushes can't land in the same microsecond.
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      final manifest = SyncManifest.fromJson(
        jsonDecode(
              utf8.decode(
                remote.files['skotiq-sync/test-machine/manifest.json']!,
              ),
            )
            as Map<String, dynamic>,
      );
      expect(manifest.bundles, hasLength(2));

      final remoteBundles = remote.files.keys
          .where((p) => p.endsWith('.nsbak'))
          .toList();
      expect(remoteBundles, hasLength(2));
      expect(remote.deletedPaths, hasLength(1));
      // The kept bundles are exactly the manifest's.
      for (final b in manifest.bundles) {
        expect(
          remote.files,
          contains('skotiq-sync/test-machine/${b.file}'),
        );
      }
    });

    test(
      'pushNow records the error and reports failure when unconfigured',
      () async {
        final service = serviceFor(db); // no serverUrl configured

        final result = await service.pushNow();

        expect(result.success, isFalse);
        expect(result.errorMessage, contains('not configured'));
        final status = await service.status();
        expect(status.lastError, contains('not configured'));
      },
    );

    test('pullAndRestore round-trips data into another database', () async {
      // Source machine: one target row, pushed to the fake remote.
      await configure(db);
      await TargetsDao(
        db,
      ).createTarget(TargetsCompanion.insert(name: 'M42', ra: 5.6, dec: -5.4));
      final push = await serviceFor(db).pushNow();
      expect(push.success, isTrue, reason: push.errorMessage);
      final bundleFile = push.remotePath!.split('/').last;

      // Destination machine: fresh database, same remote.
      final dstDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(dstDb.close);
      await configure(dstDb);
      final restore = await serviceFor(
        dstDb,
      ).pullAndRestore(machine: 'test-machine', bundleFile: bundleFile);

      expect(restore.success, isTrue, reason: restore.errorMessage);
      final targets = await TargetsDao(dstDb).getAllTargets();
      expect(targets.map((t) => t.name), contains('M42'));
    });

    test(
      'pullAndRestore aborts on hash mismatch without touching data',
      () async {
        await configure(db);
        final push = await serviceFor(db).pushNow();
        expect(push.success, isTrue, reason: push.errorMessage);

        // Corrupt the remote bundle AFTER the manifest recorded its hash.
        remote.files[push.remotePath!] = utf8.encode('{"version":"evil"}');

        final dstDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(dstDb.close);
        await configure(dstDb);
        final restore = await serviceFor(dstDb).pullAndRestore(
          machine: 'test-machine',
          bundleFile: push.remotePath!.split('/').last,
        );

        expect(restore.success, isFalse);
        expect(restore.errorMessage, contains('Hash mismatch'));
        expect(restore.itemsRestored, 0);
      },
    );

    test(
      'listRemoteMachines and listRemoteBundles surface pushed state',
      () async {
        await configure(db);
        final service = serviceFor(db);
        final push = await service.pushNow();
        expect(push.success, isTrue, reason: push.errorMessage);

        final machines = await service.listRemoteMachines();
        expect(machines.map((m) => m.name), ['test-machine']);

        final bundles = await service.listRemoteBundles('test-machine');
        expect(bundles, hasLength(1));
        expect(bundles.single.file, push.remotePath!.split('/').last);
        expect(bundles.single.sha256, isNotEmpty);
      },
    );

    test('maybeAutoPush is a no-op when auto-push is disabled', () async {
      await configure(db, autoPush: false);
      await serviceFor(db).maybeAutoPush(reason: 'test');
      expect(remote.uploadedPaths, isEmpty);
    });

    test('maybeAutoPush pushes when enabled', () async {
      await configure(db, autoPush: true);
      await serviceFor(db).maybeAutoPush(reason: 'test');
      expect(
        remote.uploadedPaths.where((p) => p.endsWith('.nsbak')),
        hasLength(1),
      );
    });
  });

  group('SyncProvider / SyncConfig', () {
    test('fromKey: absent / null / unknown maps to webdav (back-compat)', () {
      expect(SyncProvider.fromKey(null), SyncProvider.webdav);
      expect(SyncProvider.fromKey(''), SyncProvider.webdav);
      expect(SyncProvider.fromKey('nope'), SyncProvider.webdav);
      expect(SyncProvider.fromKey('webdav'), SyncProvider.webdav);
      expect(SyncProvider.fromKey('s3'), SyncProvider.s3);
    });

    test('const default keeps provider=webdav and empty S3 fields', () {
      const config = SyncConfig();
      expect(config.provider, SyncProvider.webdav);
      expect(config.s3Endpoint, isEmpty);
      expect(config.s3Region, isEmpty);
      expect(config.s3Bucket, isEmpty);
      expect(config.s3AccessKey, isEmpty);
      expect(config.s3PathStyle, isFalse);
    });

    test('isConfigured evaluates only the active provider', () {
      // WebDAV config with all S3 fields empty is configured for webdav.
      const webdav = SyncConfig(
        provider: SyncProvider.webdav,
        serverUrl: 'https://dav.example.com',
        machineName: 'box',
      );
      expect(webdav.isConfigured, isTrue);

      // Same blob but provider switched to s3 (S3 fields empty) -> not
      // configured: a half-filled inactive provider never blocks/passes.
      expect(webdav.copyWith(provider: SyncProvider.s3).isConfigured, isFalse);

      const s3 = SyncConfig(
        provider: SyncProvider.s3,
        s3Endpoint: 'https://s3.us-east-1.amazonaws.com',
        s3Region: 'us-east-1',
        s3Bucket: 'astro',
        s3AccessKey: 'AKIA',
        machineName: 'box',
      );
      expect(s3.isConfigured, isTrue);
      expect(s3.copyWith(s3Bucket: '').isConfigured, isFalse);
      expect(s3.copyWith(s3AccessKey: '').isConfigured, isFalse);
    });

    test('copyWith round-trips the six new fields', () {
      const base = SyncConfig();
      final updated = base.copyWith(
        provider: SyncProvider.s3,
        s3Endpoint: 'http://localhost:9000',
        s3Region: 'us-east-1',
        s3Bucket: 'b',
        s3AccessKey: 'ak',
        s3PathStyle: true,
      );
      expect(updated.provider, SyncProvider.s3);
      expect(updated.s3Endpoint, 'http://localhost:9000');
      expect(updated.s3Region, 'us-east-1');
      expect(updated.s3Bucket, 'b');
      expect(updated.s3AccessKey, 'ak');
      expect(updated.s3PathStyle, isTrue);
      // Untouched fields preserved.
      expect(updated.machineName, base.machineName);
      expect(updated.retainCount, base.retainCount);
    });
  });

  group('SyncService config persistence', () {
    late SkotiqDatabase db;
    late Directory tempDir;
    late LoggingService logger;
    late SettingsDao dao;
    late InMemorySecureKeyValueStore keyring;
    late SecretsStore secrets;
    late SyncService service;

    setUp(() async {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      tempDir = await Directory.systemTemp.createTemp('ns_cloud_sync_cfg_');
      logger = _testLogger(tempDir);
      dao = SettingsDao(db);
      keyring = InMemorySecureKeyValueStore();
      secrets = SecretsStore(keyring);
      service = SyncService(
        backupService: BackupService(
          database: db,
          sequenceRepository: SequenceRepository(db.sequencesDao),
          logger: logger,
        ),
        settingsDao: dao,
        secretsStore: secrets,
        logger: logger,
        targetFactory: (config, password) => InMemorySyncTarget(),
        downloadDirectoryProvider: () async => tempDir,
      );
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('absent provider key loads as webdav with existing fields', () async {
      // Simulate a pre-existing WebDAV install: server/username/machine set,
      // no provider key written.
      await dao.setSettings({
        SyncSettingsKeys.serverUrl: 'https://dav.example.com/remote.php',
        SyncSettingsKeys.username: 'astro',
        SyncSettingsKeys.machineName: 'laptop',
      });
      expect(
        await dao.getSetting(SyncSettingsKeys.provider),
        isNull,
        reason: 'precondition: no provider key persisted',
      );

      final config = await service.loadConfig();
      expect(config.provider, SyncProvider.webdav);
      expect(config.serverUrl, 'https://dav.example.com/remote.php');
      expect(config.username, 'astro');
      expect(config.machineName, 'laptop');
      expect(config.isConfigured, isTrue);
    });

    test('S3 round-trips and the secret rides keyring, not settings', () async {
      const secret = 'super-secret-key-value';
      const config = SyncConfig(
        provider: SyncProvider.s3,
        s3Endpoint: 'https://s3.us-east-1.amazonaws.com',
        s3Region: 'us-east-1',
        s3Bucket: 'astro-backups',
        s3AccessKey: 'AKIAEXAMPLE',
        s3PathStyle: true,
        machineName: 'rig',
      );
      await service.saveConfig(config, password: secret);

      final loaded = await service.loadConfig();
      expect(loaded.provider, SyncProvider.s3);
      expect(loaded.s3Endpoint, 'https://s3.us-east-1.amazonaws.com');
      expect(loaded.s3Region, 'us-east-1');
      expect(loaded.s3Bucket, 'astro-backups');
      expect(loaded.s3AccessKey, 'AKIAEXAMPLE');
      expect(loaded.s3PathStyle, isTrue);

      // Secret is in the keyring under the S3 field.
      expect(await secrets.read(SecretField.cloudSyncS3SecretKey), secret);

      // Secret is in NO app_settings value.
      for (final key in const [
        SyncSettingsKeys.provider,
        SyncSettingsKeys.serverUrl,
        SyncSettingsKeys.username,
        SyncSettingsKeys.machineName,
        SyncSettingsKeys.autoPush,
        SyncSettingsKeys.retainCount,
        SyncSettingsKeys.s3Endpoint,
        SyncSettingsKeys.s3Region,
        SyncSettingsKeys.s3Bucket,
        SyncSettingsKeys.s3AccessKey,
        SyncSettingsKeys.s3PathStyle,
      ]) {
        final value = await dao.getSetting(key);
        expect(
          value == null || !value.contains(secret),
          isTrue,
          reason: 'secret leaked into app_settings key "$key"',
        );
      }
    });

    test('webdav save writes the webdav field, not the S3 field', () async {
      const config = SyncConfig(
        provider: SyncProvider.webdav,
        serverUrl: 'https://dav.example.com',
        username: 'astro',
        machineName: 'box',
      );
      await service.saveConfig(config, password: 'pw');
      expect(await secrets.read(SecretField.cloudSyncPassword), 'pw');
      expect(await secrets.read(SecretField.cloudSyncS3SecretKey), isEmpty);
    });

    test('hasStoredSecret reflects the right keyring field', () async {
      await secrets.write(SecretField.cloudSyncPassword, 'pw');
      expect(await service.hasStoredSecret(SyncProvider.webdav), isTrue);
      expect(await service.hasStoredSecret(SyncProvider.s3), isFalse);
      expect(await service.hasStoredPassword(), isTrue);

      await secrets.write(SecretField.cloudSyncS3SecretKey, 'sk');
      expect(await service.hasStoredSecret(SyncProvider.s3), isTrue);
    });

    test('status surfaces the S3 endpoint as serverUrl (non-secret)', () async {
      const config = SyncConfig(
        provider: SyncProvider.s3,
        s3Endpoint: 'https://s3.us-east-1.amazonaws.com',
        s3Region: 'us-east-1',
        s3Bucket: 'astro',
        s3AccessKey: 'AKIA',
        machineName: 'rig',
      );
      await service.saveConfig(config, password: 'sk-must-not-appear');
      final status = await service.status();
      expect(status.serverUrl, 'https://s3.us-east-1.amazonaws.com');
      expect(
        jsonEncode(status.toJson()),
        isNot(contains('sk-must-not-appear')),
      );
      expect(jsonEncode(status.toJson()), isNot(contains('AKIA')));
    });

    test('status strips URL-embedded credentials and token queries', () async {
      const config = SyncConfig(
        provider: SyncProvider.webdav,
        serverUrl:
            'https://user:password@dav.example.com/remote.php/dav?token=secret#private',
        username: 'astro',
        machineName: 'rig',
      );
      await service.saveConfig(config, password: 'separate-keyring-secret');

      final status = await service.status();

      expect(status.serverUrl, 'https://dav.example.com/remote.php/dav');
      final encoded = jsonEncode(status.toJson());
      expect(encoded, isNot(contains('password')));
      expect(encoded, isNot(contains('token')));
      expect(encoded, isNot(contains('separate-keyring-secret')));
    });
  });

  group('SyncService.defaultTargetFactory', () {
    test('builds a WebDavSyncTarget for a webdav config', () {
      const config = SyncConfig(
        provider: SyncProvider.webdav,
        serverUrl: 'https://dav.example.com',
        machineName: 'box',
      );
      final target = SyncService.defaultTargetFactory(config, 'pw');
      expect(target, isA<WebDavSyncTarget>());
    });

    test('builds an S3SyncTarget wiring the secret into secretKey', () {
      const config = SyncConfig(
        provider: SyncProvider.s3,
        s3Endpoint: 'https://s3.us-east-1.amazonaws.com',
        s3Region: 'us-east-1',
        s3Bucket: 'astro',
        s3AccessKey: 'AKIA',
        s3PathStyle: true,
        machineName: 'rig',
      );
      final target = SyncService.defaultTargetFactory(config, 'the-secret');
      expect(target, isA<S3SyncTarget>());
      final s3 = target as S3SyncTarget;
      expect(s3.secretKey, 'the-secret');
      expect(s3.accessKey, 'AKIA');
      expect(s3.region, 'us-east-1');
      expect(s3.bucket, 'astro');
      expect(s3.pathStyle, isTrue);
    });

    test('rejects an S3 endpoint without http/https scheme', () {
      const config = SyncConfig(
        provider: SyncProvider.s3,
        s3Endpoint: 'ftp://s3.example.com',
        s3Region: 'us-east-1',
        s3Bucket: 'astro',
        s3AccessKey: 'AKIA',
        machineName: 'rig',
      );
      expect(
        () => SyncService.defaultTargetFactory(config, 'sk'),
        throwsA(isA<SyncTargetException>()),
      );
    });

    test('rejects empty S3 region / bucket (no network hit)', () {
      const noRegion = SyncConfig(
        provider: SyncProvider.s3,
        s3Endpoint: 'https://s3.example.com',
        s3Region: '',
        s3Bucket: 'astro',
        s3AccessKey: 'AKIA',
        machineName: 'rig',
      );
      const noBucket = SyncConfig(
        provider: SyncProvider.s3,
        s3Endpoint: 'https://s3.example.com',
        s3Region: 'us-east-1',
        s3Bucket: '',
        s3AccessKey: 'AKIA',
        machineName: 'rig',
      );
      expect(
        () => SyncService.defaultTargetFactory(noRegion, 'sk'),
        throwsA(isA<SyncTargetException>()),
      );
      expect(
        () => SyncService.defaultTargetFactory(noBucket, 'sk'),
        throwsA(isA<SyncTargetException>()),
      );
    });
  });

  group('SyncService S3 loopback (real SigV4 + XML, MockClient)', () {
    late Directory tempDir;
    late LoggingService logger;
    late InMemoryS3 store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ns_cloud_sync_s3_');
      logger = _testLogger(tempDir);
      store = InMemoryS3(bucket: 'astro-backups');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    SyncService s3ServiceFor(SkotiqDatabase database) {
      return SyncService(
        backupService: BackupService(
          database: database,
          sequenceRepository: SequenceRepository(database.sequencesDao),
          logger: logger,
        ),
        settingsDao: SettingsDao(database),
        secretsStore: SecretsStore(InMemorySecureKeyValueStore()),
        logger: logger,
        targetFactory: (config, password) => S3SyncTarget(
          endpoint: Uri.parse(config.s3Endpoint),
          region: config.s3Region,
          bucket: config.s3Bucket,
          accessKey: config.s3AccessKey,
          secretKey: password,
          pathStyle: config.s3PathStyle,
          client: store.client(),
        ),
        downloadDirectoryProvider: () async => tempDir,
      );
    }

    Future<void> configureS3(SkotiqDatabase database) async {
      await SettingsDao(database).setSettings({
        SyncSettingsKeys.provider: SyncProvider.s3.key,
        SyncSettingsKeys.s3Endpoint: 'http://localhost:9000',
        SyncSettingsKeys.s3Region: 'us-east-1',
        SyncSettingsKeys.s3Bucket: 'astro-backups',
        SyncSettingsKeys.s3AccessKey: 'AKIAEXAMPLE',
        SyncSettingsKeys.s3PathStyle: 'true',
        SyncSettingsKeys.machineName: 's3-machine',
      });
    }

    test(
      'pushNow + list + pullAndRestore round-trip through S3SyncTarget',
      () async {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        await configureS3(db);
        await TargetsDao(db).createTarget(
          TargetsCompanion.insert(name: 'NGC7000', ra: 20.9, dec: 44.5),
        );

        final push = await s3ServiceFor(db).pushNow();
        expect(push.success, isTrue, reason: push.errorMessage);
        expect(push.remotePath, startsWith('skotiq-sync/s3-machine/'));

        // Manifest + bundle really landed in the object store.
        expect(
          store.objects.keys,
          contains('skotiq-sync/s3-machine/manifest.json'),
        );
        expect(store.objects.keys, contains(push.remotePath));

        // list-objects-v2 -> machines / bundles surface correctly.
        final svc = s3ServiceFor(db);
        final machines = await svc.listRemoteMachines();
        expect(machines.map((m) => m.name), contains('s3-machine'));
        final bundles = await svc.listRemoteBundles('s3-machine');
        expect(bundles, hasLength(1));
        expect(bundles.single.sha256, isNotEmpty);

        // Pull into a fresh DB and confirm the row crossed over (sha256 verified
        // against the manifest along the way).
        final dstDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(dstDb.close);
        await configureS3(dstDb);
        final restore = await s3ServiceFor(dstDb).pullAndRestore(
          machine: 's3-machine',
          bundleFile: push.remotePath!.split('/').last,
        );
        expect(restore.success, isTrue, reason: restore.errorMessage);
        final targets = await TargetsDao(dstDb).getAllTargets();
        expect(targets.map((t) => t.name), contains('NGC7000'));
      },
    );

    test('_closeIfOwned does not throw for an S3SyncTarget', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await configureS3(db);
      // testConnection builds an S3SyncTarget and runs it through the
      // finally { _closeIfOwned(target) } path. The injected MockClient is
      // not owned, so close() is a no-op and must not throw.
      await s3ServiceFor(db).testConnection();
    });
  });
}
