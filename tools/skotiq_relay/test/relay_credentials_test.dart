import 'dart:io';

import 'package:skotiq_relay/skotiq_relay.dart';
import 'package:test/test.dart';

void main() {
  test('saved credentials stay private after replacement', () async {
    final directory = await Directory.systemTemp.createTemp(
      'relay-credentials-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/credentials.json');
    final store = FileRelayCredentialsStore(file.path);
    for (final secret in ['first-secret', 'replacement-secret']) {
      await store.save(
        RelayCredentials(applianceId: 'test-appliance', secret: secret),
      );
      expect((await store.load())!.secret, secret);
      if (!Platform.isWindows) {
        expect((await file.stat()).mode & 0x1ff, 0x180);
      }
      expect(await File('${file.path}.tmp').exists(), isFalse);
    }
  });

  test(
    'a permission failure leaves the existing secret untouched',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'relay-credential-permissions-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/credentials.json');
      final store = FileRelayCredentialsStore(file.path);
      await store.save(
        const RelayCredentials(applianceId: 'test', secret: 'original'),
      );
      final original = await file.readAsString();
      final bin = await Directory('${directory.path}/bin').create();
      final chmod = File('${bin.path}/chmod');
      await chmod.writeAsString('#!/bin/sh\nexit 1\n');
      final executable = await Process.run('chmod', ['700', chmod.path]);
      expect(executable.exitCode, 0);
      final child = File('${directory.path}/save.dart');
      await child.writeAsString(r'''
import 'dart:io';
import 'package:skotiq_relay/skotiq_relay.dart';

Future<void> main(List<String> args) async {
  try {
    await FileRelayCredentialsStore(args.single).save(
      const RelayCredentials(applianceId: 'test', secret: 'replacement'),
    );
    exitCode = 1;
  } on FileSystemException {
    exitCode = 0;
  }
}
''');
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          child.path,
          file.path,
        ],
        environment: {'PATH': bin.path},
      );
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
      expect(await file.readAsString(), original);
      expect(await File('${file.path}.tmp').readAsString(), isEmpty);
    },
    skip: Platform.isWindows ? 'POSIX permission failure' : false,
  );
}
