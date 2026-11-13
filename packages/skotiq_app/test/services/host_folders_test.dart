// One rule for a folder the app writes into, on this computer and on a linked
// host: a full path to a folder that exists and takes a file. The capture
// panel used to store a picked folder unchecked, Settings created any typed
// folder, and onboarding refused one that did not exist yet, so the same
// folder was accepted on one screen and refused on another.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_app/services/host_folders.dart';
import 'package:skotiq_core/backend.dart';

class _MockHostFiles extends Mock implements HostFiles {}

void main() {
  const folders = HostFolders();
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('sk-folders-'));
  tearDown(() => root.deleteSync(recursive: true));

  group('on this computer', () {
    test('a folder that takes a file is usable, and keeps no probe', () async {
      expect(await folders.check(root.path, host: null), isA<FolderUsable>());
      expect(root.listSync(), isEmpty);
    });

    test('a folder that is not there yet is missing, and is not made',
        () async {
      final path = p.join(root.path, 'Lights');
      expect(await folders.check(path, host: null), isA<FolderMissing>());
      expect(Directory(path).existsSync(), isFalse);
    });

    test('a file is refused', () async {
      final file = File(p.join(root.path, 'notes.txt'))..writeAsStringSync('');
      final verdict = await folders.check(file.path, host: null);
      expect(verdict, isA<FolderRefused>());
    });

    test('a relative path is refused with an example of a full one',
        () async {
      final verdict = await folders.check('Astro/Lights', host: null);
      expect(
        (verdict as FolderRefused).reason,
        startsWith('Enter a full path'),
      );
    });
  });

  group('on a linked host', () {
    late _MockHostFiles host;
    setUp(() => host = _MockHostFiles());

    void answer(Map<String, dynamic> result) => when(
          () => host.validateRemoteDirectory(
            any(),
            mustExist: any(named: 'mustExist'),
            mustBeWritable: any(named: 'mustBeWritable'),
          ),
        ).thenAnswer((_) async => result);

    test('the host is asked by the same rule', () async {
      answer({'valid': true, 'exists': true, 'writable': true});

      expect(await folders.check('/mnt/captures', host: host),
          isA<FolderUsable>());
      verify(() => host.validateRemoteDirectory(
            '/mnt/captures',
            mustExist: true,
            mustBeWritable: true,
          )).called(1);
    });

    test('a folder the host does not have is missing', () async {
      answer({'valid': false, 'exists': false, 'writable': false});
      expect(await folders.check('/mnt/new', host: host), isA<FolderMissing>());
    });

    test('a folder the host cannot write is refused', () async {
      answer({'valid': false, 'exists': true, 'writable': false});
      expect(await folders.check('/mnt/ro', host: host), isA<FolderRefused>());
    });

    test('a host that does not answer leaves the folder unchecked', () async {
      when(
        () => host.validateRemoteDirectory(
          any(),
          mustExist: any(named: 'mustExist'),
          mustBeWritable: any(named: 'mustBeWritable'),
        ),
      ).thenThrow(const SocketException('no route'));
      expect(await folders.check('/mnt/captures', host: host),
          isA<FolderUnchecked>());
    });
  });
}
