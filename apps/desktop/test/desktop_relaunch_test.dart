// Changing role restarts the app without the flags and variables that fixed
// the old role, and the new process waits for the old one to let go.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/desktop_relaunch.dart';

void main() {
  test('role flags are dropped and the old pid is passed on', () {
    expect(
      relaunchArguments([
        '--remote-host=192.168.1.32',
        '--remote-port=8099',
        '--remote-token=secret',
        '--serve',
        '--relaunched-from=1',
        '--some-other=1',
      ], 4242),
      ['--some-other=1', '--relaunched-from=4242'],
    );
  });

  test('role variables are blanked for the next process', () {
    expect(relaunchEnvironment(), {
      'SKOTIQ_REMOTE_HOST': '',
      'SKOTIQ_REMOTE_PORT': '',
      'SKOTIQ_REMOTE_TOKEN': '',
      'SKOTIQ_REMOTE_SCHEME': '',
      'SKOTIQ_SERVE': '',
    });
  });

  test('the relaunch pid is read back', () {
    expect(relaunchedFromPid(['--relaunched-from=77']), 77);
    expect(relaunchedFromPid(['--serve']), isNull);
  });

  test('waits until the previous instance lets go, then gives up', () async {
    var checks = 0;
    final freed = await waitForPreviousInstance(
      () async => ++checks < 3,
      interval: const Duration(milliseconds: 1),
    );
    expect(freed, isTrue);
    expect(checks, 3);
    final never = await waitForPreviousInstance(
      () async => true,
      timeout: const Duration(milliseconds: 20),
      interval: const Duration(milliseconds: 5),
    );
    expect(never, isFalse);
  });
}
