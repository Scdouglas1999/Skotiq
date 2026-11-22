// A manual GoTo waits as long for arrival as the native bridge waits on a
// long slew (Timeouts::long_slew); both read test_fixtures/timeouts.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/mount_slew_watcher.dart';

const _fixturePath = '../../test_fixtures/timeouts/long_slew.json';

void main() {
  test('the GoTo arrival timeout is the native long-slew timeout', () {
    final fixture =
        jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    expect(
      MountSlewWatcher.defaultCompletionTimeout,
      Duration(seconds: fixture['long_slew_seconds'] as int),
    );
  });
}
