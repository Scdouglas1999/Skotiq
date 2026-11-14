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
}
