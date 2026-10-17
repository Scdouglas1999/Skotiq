// The two credential files Skotiq keeps in the application-support
// directory must be owner-only.
//
// Live defect (fresh-install audit): a headless start created
// `push_secret.txt` and `remote_access_token.txt` at 0644 while the profile
// database beside them was 0600 — the two files that ARE credentials were the
// world-readable ones. On Linux the app-support directory is created 0755, so
// the directory is no protection either: any local account could read the
// token that grants control of the rig.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/update_wiring.dart';
import 'package:skotiq_desktop/secret_file.dart';

/// The mode bits as `stat` reports them, e.g. `600`.
Future<String> octalMode(File file) async {
  final result = await Process.run('stat', ['-c', '%a', file.path]);
  expect(result.exitCode, 0, reason: 'stat failed: ${result.stderr}');
  return (result.stdout as String).trim();
}

void main() {
  late Directory appData;

  setUp(() async {
    appData = await Directory.systemTemp.createTemp('sk-secret-file-test-');
  });

  tearDown(() async {
    if (await appData.exists()) {
      await appData.delete(recursive: true);
    }
  });

  test(
    'a freshly generated push secret is owner-only',
    () async {
      final secret = await getOrCreatePushSecret(
        LoggingService(),
        logSource: 'test',
        appDataDir: appData,
      );
      expect(secret, isNotEmpty);

      final file = File('${appData.path}/push_secret.txt');
      expect(await file.exists(), isTrue);
      expect(
        await octalMode(file),
        '600',
        reason: 'the LAN-push secret must not be readable by other local users',
      );
    },
    skip: Platform.isWindows ? 'POSIX file modes only' : null,
  );

  test(
    'an existing world-readable secret is repaired on read',
    () async {
      // What an older build left behind.
      final file = File('${appData.path}/push_secret.txt');
      await file.writeAsString('pre-existing-secret');
      await Process.run('chmod', ['644', file.path]);
      expect(await octalMode(file), '644');

      final secret = await getOrCreatePushSecret(
        LoggingService(),
        logSource: 'test',
        appDataDir: appData,
      );

      expect(
        secret,
        'pre-existing-secret',
        reason: 'the secret must not rotate',
      );
      expect(
        await octalMode(file),
        '600',
        reason: 'reading an existing secret must repair its mode in place',
      );
    },
    skip: Platform.isWindows ? 'POSIX file modes only' : null,
  );

  test(
    'writeSecretFile never exposes the bytes at a wider mode',
    () async {
      // Create the file world-readable first, then write through the helper:
      // the contents must land only after the mode is restricted.
      final file = File('${appData.path}/remote_access_token.txt');
      await file.writeAsString('');
      await Process.run('chmod', ['644', file.path]);

      await writeSecretFile(file, 'deadbeef');

      expect(await file.readAsString(), 'deadbeef');
      expect(await octalMode(file), '600');
    },
    skip: Platform.isWindows ? 'POSIX file modes only' : null,
  );
}
