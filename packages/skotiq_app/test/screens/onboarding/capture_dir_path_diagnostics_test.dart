// Two live findings from the onboarding capture-folder step (Step 10 of 13),
// both reproduced by driving the release build on a scratch profile:
//
//  * typing `/root` — a folder that exists but this process cannot write —
//    answered "Not writable: Cannot open file". That is dart:io's generic
//    phrase; the actual reason (Permission denied) sits in OSError and was
//    thrown away, so every rejection read the same and none of them said what
//    to do about it.
//  * typing `~/Documents` answered "That folder does not exist." even though it
//    does. A tilde path is what people paste out of a terminal and dart:io does
//    not expand it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/capture_dir_step.dart';

void main() {
  group('write-probe failures name the reason', () {
    test('an errno reason replaces the generic dart:io phrase', () {
      const error = FileSystemException(
        'Cannot open file',
        '/root/.skotiq_write_probe',
        OSError('Permission denied', 13),
      );

      expect(describeCaptureDirWriteFailure(error),
          'Not writable: Permission denied');
    });

    test('a read-only mount says so rather than "Cannot open file"', () {
      const error = FileSystemException(
        'Cannot open file',
        '/mnt/ro/.skotiq_write_probe',
        OSError('Read-only file system', 30),
      );

      expect(describeCaptureDirWriteFailure(error),
          'Not writable: Read-only file system');
    });

    test('with no errno it falls back to the generic phrase', () {
      const error = FileSystemException('Cannot open file', '/x');

      expect(describeCaptureDirWriteFailure(error),
          'Not writable: Cannot open file');
    });
  });

  group('tilde paths resolve against home', () {
    final home = Platform.environment['HOME'];

    test('a leading ~/ expands to the home directory', () {
      if (home == null || home.trim().isEmpty) {
        markTestSkipped('no HOME in this environment');
        return;
      }

      expect(
        expandCaptureDirHome('~/Astro/Captures'),
        '$home${Platform.pathSeparator}Astro/Captures',
      );
      expect(expandCaptureDirHome('~'), home);
    });

    test('a path with no tilde is returned untouched', () {
      expect(expandCaptureDirHome('/mnt/nvme/astro'), '/mnt/nvme/astro');
      // Not a home reference: only a leading `~` alone or `~/` is expanded, so
      // a folder that legitimately starts with a tilde is left alone.
      expect(expandCaptureDirHome('~backup/astro'), '~backup/astro');
      expect(expandCaptureDirHome(''), '');
    });
  });
}
