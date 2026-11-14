// A host keeps its crash-recovery checkpoints beside the database it opened,
// window and daemon alike, so a checkpoint is only ever offered by the
// database whose run wrote it. Checkpoints earlier builds kept in the data
// directory are carried over when that directory is this instance's own.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_desktop/host/host_checkpoint_directory.dart';

const _checkpoint = 'skotiq_session.checkpoint';

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;

  setUp(() {
    root = Directory.systemTemp.createTempSync('sk-checkpoints-');
    support = Directory(p.join(root.path, 'support'))..createSync();
    documents = Directory(p.join(root.path, 'documents'))..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<Directory> resolve(Map<String, String> environment) =>
      resolveHostCheckpointDirectory(
        environment: environment,
        applicationSupportDirectoryProvider: () async => support,
        documentsDirectoryProvider: () async => documents,
      );

  void write(String directory, String content) {
    Directory(directory).createSync(recursive: true);
    File(p.join(directory, _checkpoint)).writeAsStringSync(content);
  }

  String? read(Directory directory) {
    final file = File(p.join(directory.path, _checkpoint));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  test('checkpoints sit beside the database the host opened', () async {
    final database = p.join(root.path, 'db');
    final resolved = await resolve({skotiqDatabaseDirEnv: database});

    expect(resolved.path, p.join(database, 'checkpoints'));
    expect(resolved.existsSync(), isTrue);
  });

  test('an instance data directory keeps its checkpoints inside it', () async {
    final data = p.join(root.path, 'instance');
    final resolved = await resolve({skotiqDataDirEnv: data});

    expect(p.isWithin(data, resolved.path), isTrue);
    expect(
      Directory(p.join(support.path, 'checkpoints')).existsSync(),
      isFalse,
    );
  });

  test('a relative database directory fails loudly', () async {
    await expectLater(
      resolve({skotiqDatabaseDirEnv: 'relative/db'}),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('a window checkpoint from an earlier build is carried over', () async {
    write(support.path, 'window night');

    final resolved = await resolve({});

    expect(read(resolved), 'window night');
    expect(File(p.join(support.path, _checkpoint)).existsSync(), isFalse);
  });

  test('a daemon checkpoint from an earlier build is carried over', () async {
    final data = p.join(root.path, 'var', 'data');
    write(p.join(data, 'checkpoints'), 'daemon night');

    final resolved = await resolve({
      skotiqDataDirEnv: data,
      skotiqDatabaseDirEnv: p.join(root.path, 'var', 'database'),
    });

    expect(read(resolved), 'daemon night');
  });

  test(
    'a shared data folder is left alone when only the database is named',
    () async {
      write(support.path, 'someone else');

      final resolved = await resolve({
        skotiqDatabaseDirEnv: p.join(root.path, 'db'),
      });

      expect(read(resolved), isNull);
      expect(File(p.join(support.path, _checkpoint)).existsSync(), isTrue);
    },
  );

  test('this database\'s own checkpoint is never replaced', () async {
    write(support.path, 'stale');
    write(p.join(documents.path, 'Skotiq', 'checkpoints'), 'tonight');

    final resolved = await resolve({});

    expect(read(resolved), 'tonight');
    expect(File(p.join(support.path, _checkpoint)).existsSync(), isTrue);
  });
}
