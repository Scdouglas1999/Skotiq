// The remote clients (cloud sync, the hub, the shared calibration library)
// bound every exchange by the time no bytes move, against a real loopback
// server: a stalled server ends the call, a slow but moving link finishes.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

import 'backup_restore_support.dart';

/// A loopback server whose handling of each request the test decides.
class _Server {
  _Server._(this._server);

  final HttpServer _server;
  final List<HttpRequest> held = [];
  final List<Object> errors = [];

  static Future<_Server> start(
    Future<void> Function(HttpRequest request, _Server server) handle,
  ) async {
    final server = _Server._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(
      (request) => handle(request, server).then(
        (_) {},
        // The client giving up closes the connection under a handler that is
        // still writing; that is the client's bound working.
        onError: server.errors.add,
      ),
    );
    return server;
  }

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);
}

/// Accepts the request and never answers.
Future<void> _neverAnswer(HttpRequest request, _Server server) async {
  server.held.add(request);
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sk_remote_http_bounds_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('S3 sync', () {
    test('a stalled endpoint ends the push, and the next push is not refused '
        'as already in progress', () async {
      final server = await _Server.start(_neverAnswer);
      addTearDown(server.close);
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await SettingsDao(db).setSettings({
        SyncSettingsKeys.provider: SyncProvider.s3.key,
        SyncSettingsKeys.s3Endpoint: server.uri.toString(),
        SyncSettingsKeys.s3Region: 'us-east-1',
        SyncSettingsKeys.s3Bucket: 'astro-backups',
        SyncSettingsKeys.s3AccessKey: 'AKIAEXAMPLE',
        SyncSettingsKeys.s3PathStyle: 'true',
        SyncSettingsKeys.machineName: 's3-machine',
      });
      final logger = testLogger(tmp);
      final service = SyncService(
        backupService: BackupService(database: db, logger: logger),
        settingsDao: SettingsDao(db),
        secretsStore: SecretsStore(InMemorySecureKeyValueStore()),
        logger: logger,
        targetFactory: (config, password) => S3SyncTarget(
          endpoint: Uri.parse(config.s3Endpoint),
          region: config.s3Region,
          bucket: config.s3Bucket,
          accessKey: config.s3AccessKey,
          secretKey: password,
          pathStyle: config.s3PathStyle,
          timeout: const Duration(milliseconds: 300),
        ),
        downloadDirectoryProvider: () async => tmp,
      );

      final first = await service.pushNow();
      expect(first.success, isFalse);
      expect(first.errorMessage, contains('timed out'));
      expect(service.pushInProgress, isFalse);

      final second = await service.pushNow();
      expect(second.errorMessage, isNot(contains('already in progress')));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
}
