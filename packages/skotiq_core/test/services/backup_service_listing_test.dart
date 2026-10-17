import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase database;
  late Directory root;
  late LoggingService logger;

  setUp(() async {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('backup_listing_test_');
    logger = LoggingService(
      applicationSupportDirectoryProvider: () async => root,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
  });

  tearDown(() async {
    await database.close();
    await logger.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  BackupService service(Future<Directory> Function() directory) =>
      BackupService(
        database: database,
        sequenceRepository: SequenceRepository(database.sequencesDao),
        logger: logger,
        backupDirectoryProvider: directory,
      );

  test('a genuinely absent backup directory remains an empty list', () async {
    final missing = Directory('${root.path}/missing');
    expect(await service(() async => missing).listBackups(), isEmpty);
  });

  test('backup files are filtered and sorted newest first', () async {
    final older = File('${root.path}/older.nsbackup');
    final newer = File('${root.path}/newer.json');
    await older.writeAsString('{}');
    await newer.writeAsString('{}');
    await File('${root.path}/ignore.txt').writeAsString('not a backup');
    await older.setLastModified(DateTime.utc(2026, 1, 1));
    await newer.setLastModified(DateTime.utc(2026, 1, 2));

    expect(
      (await service(
        () async => root,
      ).listBackups()).map((file) => file.uri.pathSegments.last),
      ['newer.json', 'older.nsbackup'],
    );
  });

  test(
    'directory resolution failures propagate instead of looking empty',
    () async {
      final failing = service(
        () => throw const FileSystemException('backup volume unavailable'),
      );

      await expectLater(
        failing.listBackups(),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
