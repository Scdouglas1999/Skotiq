// The backup folder must be movable, and moving it must move everything that
// touches it.
//
// Live: "Enable automatic backups" defaults ON at a 24 h interval with
// "Maximum backups 7", and the destination was fixed — Files & Storage neither
// named it nor offered any way to change it, while retention DELETED the oldest
// bundles out of it. Backups belong on the drive the operator actually backs
// up; an observatory PC's system volume is routinely the smallest one on the
// machine, and the default folder follows the database onto it.
//
// Every consumer (create, auto-save, list, retention, the headless handlers,
// sync) goes through BackupService.getBackupDirectory, so these tests drive the
// service rather than the resolver helper.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase database;
  late Directory root;
  late Directory chosen;
  late LoggingService logger;
  late BackupService service;

  setUp(() async {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('backup_directory_test_');
    chosen = Directory('${root.path}/on-the-big-disk');
    logger = LoggingService(
      applicationSupportDirectoryProvider: () async => root,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    // No backupDirectoryProvider: production constructs the service exactly
    // this way, so the setting is the only thing that can redirect it.
    service = BackupService(
      database: database,
      sequenceRepository: SequenceRepository(database.sequencesDao),
      logger: logger,
    );
  });

  tearDown(() async {
    await database.close();
    await logger.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a chosen folder is where backups are actually written', () async {
    await service.setBackupDirectory(chosen.path);

    expect((await service.getBackupDirectory()).path, chosen.path);

    final result = await service.createBackup();
    expect(result.success, isTrue, reason: result.errorMessage);
    expect(result.filePath, startsWith(chosen.path));
    expect(File(result.filePath!).existsSync(), isTrue);

    // Auto-save (the scheduled path retention prunes) and the listing that
    // retention reads both follow the same choke point.
    final auto = await service.autoSaveBackup();
    expect(auto.success, isTrue, reason: auto.errorMessage);
    expect(auto.filePath, startsWith(chosen.path));

    final listed = await service.listBackups();
    expect(listed, hasLength(2));
    for (final file in listed) {
      expect(file.path, startsWith(chosen.path));
    }
  });

  test('the chosen folder is created eagerly, not at 3am', () async {
    expect(chosen.existsSync(), isFalse);
    await service.setBackupDirectory(chosen.path);
    expect(chosen.existsSync(), isTrue);
  });

  test('a folder that cannot be created is refused at the picker', () async {
    // A path under a regular FILE can never be a directory.
    final blocker = File('${root.path}/not-a-directory');
    await blocker.writeAsString('x');

    await expectLater(
      service.setBackupDirectory('${blocker.path}/backups'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await service.getConfiguredBackupDirectory(), isNull);
  });

  test('clearing the choice stops writing to the old folder', () async {
    await service.setBackupDirectory(chosen.path);
    final first = await service.createBackup();
    expect(first.success, isTrue, reason: first.errorMessage);
    expect(chosen.listSync(), hasLength(1));

    await service.setBackupDirectory(null);
    expect(await service.getConfiguredBackupDirectory(), isNull);

    // Whatever the default resolves to in this environment, it is not the
    // folder that was just handed back.
    await service.createBackup();
    expect(
      chosen.listSync(),
      hasLength(1),
      reason: 'the abandoned folder must not keep receiving backups',
    );
  });

  test('blank input means "use the default", not a folder named ""', () async {
    await service.setBackupDirectory(chosen.path);
    await service.setBackupDirectory('   ');
    expect(await service.getConfiguredBackupDirectory(), isNull);
  });

  test('the bundle does not carry this machine’s backup folder', () async {
    final settings = SettingsDao(database);
    await settings.setSetting('some.other.setting', 'kept');
    await service.setBackupDirectory(chosen.path);

    final result = await service.createBackup();
    expect(result.success, isTrue, reason: result.errorMessage);
    final bundle =
        jsonDecode(await File(result.filePath!).readAsString())
            as Map<String, dynamic>;
    final exported = bundle['settings'] as Map<String, dynamic>;

    expect(exported.containsKey('some.other.setting'), isTrue);
    expect(
      exported.containsKey(BackupService.backupDirectorySettingKey),
      isFalse,
      reason:
          'restoring this bundle elsewhere would repoint that install’s '
          'backup folder — and its retention deletes — at this machine’s '
          'path',
    );
  });

  test('restoring a bundle cannot move this install’s backup folder', () async {
    await service.setBackupDirectory(chosen.path);

    // A hand-written bundle that DOES carry the key, which is the only way one
    // can reach a restore now that the exporter strips it.
    final foreign = File('${root.path}/foreign.skbackup');
    await foreign.writeAsString(
      jsonEncode({
        'version': BackupService.backupVersion,
        'createdAt': DateTime.now().toIso8601String(),
        'settings': {
          BackupService.backupDirectorySettingKey: '/some/other/machine',
          'some.other.setting': 'restored',
        },
        'equipmentProfiles': <dynamic>[],
        'sequences': <dynamic>[],
        'targets': <dynamic>[],
      }),
    );

    final restore = await service.restoreBackup(filePath: foreign.path);
    expect(restore.success, isTrue, reason: restore.errorMessage);
    expect(
      await SettingsDao(database).getSetting('some.other.setting'),
      'restored',
    );
    expect(await service.getConfiguredBackupDirectory(), chosen.path);
  });
}
