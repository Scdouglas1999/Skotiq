import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/backup_handlers.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import 'handler_test_helpers.dart';

void main() {
  group('BackupHandlers', () {
    late ProviderContainer container;
    late BackupHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = BackupHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test(
      'create backup malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCreateBackup(
            Request(
              'POST',
              Uri.parse('http://localhost/api/backup/create'),
              body: '{',
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test('remote create rejects a caller-selected server path', () async {
      final response = await handlers.handleCreateBackup(
        Request(
          'POST',
          Uri.parse('http://localhost/api/backup/create'),
          body: jsonEncode({'customPath': '/tmp/overwrite.nsbackup'}),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'host_managed_backup_path');
    });

    test(
      'upload restore oversized content length returns JSON too large',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleUploadRestoreBackup(
            Request(
              'POST',
              Uri.parse('http://localhost/api/backup/upload-restore'),
              headers: {'content-length': '${257 * 1024 * 1024}'},
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.requestEntityTooLarge);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'Backup upload is too large');
        expect(body['maxBytes'], 256 * 1024 * 1024);
      },
    );

    test('upload restore invalid filename returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleUploadRestoreBackup(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/backup/upload-restore?fileName=bad.exe',
            ),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(
        body['error'],
        'Invalid backup filename. Use a .nsbackup or .json filename.',
      );
    });

    test('restore is rejected while a sequence is active', () async {
      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;

      final response = await handlers.handleRestoreBackup(
        Request(
          'POST',
          Uri.parse('http://localhost/api/backup/restore'),
          body: jsonEncode({'id': 'backup-id'}),
        ),
      );

      expect(response.statusCode, HttpStatus.conflict);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'imaging_active');
    });

    test('upload restore is rejected during a standalone capture', () async {
      container.read(sessionStateProvider.notifier).setCapturing(true);

      final response = await handlers.handleUploadRestoreBackup(
        Request(
          'POST',
          Uri.parse(
            'http://localhost/api/backup/upload-restore?fileName=test.nsbackup',
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.conflict);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'imaging_active');
    });
  });

  // D1: the restore wrote the backup straight to the database while the
  // process kept its pre-restore `AppSettings` in memory. The next settings
  // write merged onto that stale snapshot and persisted the whole map, wiping
  // every restored value. Restoring must re-hydrate the providers that own the
  // restored data.
  group('BackupHandlers restore re-hydrates in-memory state', () {
    late Directory backupDir;
    late ProviderContainer container;
    late BackupHandlers handlers;

    setUp(() {
      backupDir = Directory.systemTemp.createTempSync('ns-backup-restore');
      addTearDown(() => backupDir.deleteSync(recursive: true));
      container = createHeadlessTestContainer(
        overrides: [
          backupServiceProvider.overrideWith(
            (ref) => BackupService(
              database: ref.watch(databaseProvider),
              sequenceRepository: ref.watch(sequenceRepositoryProvider),
              logger: ref.watch(loggingServiceProvider),
              backupDirectoryProvider: () async => backupDir,
            ),
          ),
        ],
      );
      handlers = BackupHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('restored settings are what the next reader sees', () async {
      final dao = container.read(settingsDaoProvider);
      final service = container.read(backupServiceProvider);

      await dao.setSetting('bortle_class', '2');
      await dao.setSetting('observer_name', 'restored-observer');
      final backupId = const Uuid().v4();
      final created = await service.createBackup(
        customPath:
            '${backupDir.path}/skotiq-backup-manual-$backupId.nsbackup',
      );
      expect(created.success, isTrue, reason: created.errorMessage);

      // Drift the live database away from the backup, then let the process
      // take its in-memory snapshot — the restore must re-hydrate it.
      await dao.setSetting('bortle_class', '7');
      await dao.setSetting('observer_name', 'stale-observer');
      final stale = await container.read(appSettingsProvider.future);
      expect(stale.bortleClass, 7);
      expect(stale.observerName, 'stale-observer');

      final response = await handlers.handleRestoreBackup(
        Request(
          'POST',
          Uri.parse('http://localhost/api/backup/restore'),
          body: jsonEncode({'id': backupId}),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'restored');

      expect(await dao.getSetting('bortle_class'), '2');
      final live = await container.read(appSettingsProvider.future);
      expect(
        live.bortleClass,
        2,
        reason:
            'the in-memory settings must come from the restored database, '
            'or the next write flushes the pre-restore snapshot back over it',
      );
      expect(live.observerName, 'restored-observer');
      expect(body['reloaded'], isTrue);
    });
  });
}
