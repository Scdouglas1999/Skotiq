import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
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
          body: jsonEncode({'customPath': '/tmp/overwrite.skbackup'}),
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
        'Invalid backup filename. Use a .skbackup or .json filename.',
      );
    });

    test('restore is rejected while a sequence is active', () async {
      container
          .read(runRecordProvider.notifier)
          .setLifecycle(SequenceExecutionState.running);

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
            'http://localhost/api/backup/upload-restore?fileName=test.skbackup',
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
      backupDir = Directory.systemTemp.createTempSync('sk-backup-restore');
      addTearDown(() => backupDir.deleteSync(recursive: true));
      container = createHeadlessTestContainer(
        overrides: [
          backupServiceProvider.overrideWith(
            (ref) => BackupService(
              database: ref.watch(databaseProvider),
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

    test('a merge adds records, leaves the settings and says so', () async {
      final dao = container.read(settingsDaoProvider);
      final service = container.read(backupServiceProvider);
      final database = container.read(databaseProvider);

      await dao.setSetting('bortle_class', '2');
      await database.customStatement(
        "INSERT INTO targets (id, name, ra, dec) VALUES (4, 'In the backup', 1, 2)",
      );
      final backupId = const Uuid().v4();
      final created = await service.createBackup(
        customPath: '${backupDir.path}/skotiq-backup-manual-$backupId.skbackup',
      );
      expect(created.success, isTrue, reason: created.errorMessage);

      await dao.setSetting('bortle_class', '7');
      await database.customStatement('DELETE FROM targets');
      expect((await container.read(appSettingsProvider.future)).bortleClass, 7);

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
      expect(body['mode'], 'merge');
      expect(body['categoryCounts'], {'targets': 1});
      expect(body['message'], contains('Your settings were not changed'));
      expect(body['reloaded'], isTrue);

      expect(await dao.getSetting('bortle_class'), '7');
      expect((await container.read(appSettingsProvider.future)).bortleClass, 7);
      expect((await database.targetsDao.getAllTargets()).map((t) => t.name), [
        'In the backup',
      ]);

      final state = await handlers.handleRestoreState(
        Request('GET', Uri.parse('http://localhost/api/backup/restore-state')),
      );
      expect(jsonDecode(await state.readAsString()), {
        'progress': null,
        'pendingReplace': null,
        'lastReplace': null,
      });
    });

    test(
      'an uploaded copy of a backup that is here gets an id of its own',
      () async {
        final service = container.read(backupServiceProvider);
        final backupId = const Uuid().v4();
        final name = 'skotiq-backup-manual-$backupId.skbackup';
        final created = await service.createBackup(
          customPath: '${backupDir.path}/$name',
        );
        expect(created.success, isTrue, reason: created.errorMessage);
        final bytes = File(created.filePath!).readAsBytesSync();

        for (var copy = 0; copy < 2; copy++) {
          final response = await handlers.handleUploadRestoreBackup(
            Request(
              'POST',
              Uri.parse(
                'http://localhost/api/backup/upload-restore?fileName=$name',
              ),
              body: bytes,
            ),
          );
          expect(response.statusCode, HttpStatus.ok);
        }

        Future<List<Map>> list() async {
          final response = await handlers.handleListBackups(
            Request('GET', Uri.parse('http://localhost/api/backup/list')),
          );
          return ((jsonDecode(await response.readAsString()) as Map)['backups']
                  as List)
              .cast<Map>();
        }

        final listed = await list();
        expect(listed, hasLength(3));
        expect(listed.map((b) => b['id']).toSet(), hasLength(3));
        expect(listed.map((b) => b['id']), contains(backupId));

        // Each id is one file: deleting a copy leaves the original.
        final copyId = listed.firstWhere((b) => b['id'] != backupId)['id'];
        await handlers.handleDeleteBackup(
          Request('DELETE', Uri.parse('http://localhost/api/backup/$copyId')),
          copyId as String,
        );
        final left = await list();
        expect(left, hasLength(2));
        expect(left.map((b) => b['fileName']), contains(name));
      },
    );

    test(
      'two files that already share a UUID are listed under two ids',
      () async {
        final service = container.read(backupServiceProvider);
        final backupId = const Uuid().v4();
        final created = await service.createBackup(
          customPath:
              '${backupDir.path}/skotiq-backup-manual-$backupId.skbackup',
        );
        File(created.filePath!).copySync(
          '${backupDir.path}/skotiq-backup-manual-${backupId}_upload_x.skbackup',
        );
        final response = await handlers.handleListBackups(
          Request('GET', Uri.parse('http://localhost/api/backup/list')),
        );
        final ids = [
          for (final b
              in (jsonDecode(await response.readAsString()) as Map)['backups']
                  as List)
            (b as Map)['id'],
        ];
        expect(ids.toSet(), hasLength(2));
      },
    );
  });
}
