import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/single_instance_lock.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_lock_test_');
    dbFile = File(p.join(tempDir.path, 'skotiq.db'));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // Windows can hold a handle a moment longer than the test does.
      }
    }
  });

  test('acquiring records the holder and never touches the database', () async {
    final lock = await SingleInstanceLock.acquire(dbFile);
    addTearDown(lock.release);

    expect(lock.isNoOp, isFalse);
    expect(lock.lockPath, equals('${dbFile.path}.lock'));
    expect(await File(lock.lockPath).exists(), isTrue);
    expect(await File(lock.lockPath).readAsString(), contains('pid=$pid'));

    // The guard runs before the integrity check specifically so that a
    // contended launch never opens, creates or rotates the database.
    expect(
      await dbFile.exists(),
      isFalse,
      reason: 'The lock must not create or modify the database file.',
    );
  });

  test('re-opening inside one process shares the same claim', () async {
    // Closing a database and opening it again — a rebuilt provider
    // container, a test that constructs its own — is legitimate and must
    // not be mistaken for a second instance. The hazard the guard exists
    // for is two *processes*, which the cross-process test below covers.
    final first = await SingleInstanceLock.acquire(dbFile);
    final second = await SingleInstanceLock.acquire(dbFile);
    addTearDown(second.release);

    expect(identical(first, second), isTrue);
    expect(second.holders, 2);

    // The OS lock survives until the last holder lets go.
    await first.release();
    expect(second.holders, 1);
  });

  test('releasing every hold frees the lock for the next opener', () async {
    final first = await SingleInstanceLock.acquire(dbFile);
    await first.release();
    expect(first.holders, 0);

    final second = await SingleInstanceLock.acquire(dbFile);
    addTearDown(second.release);
    expect(second.isNoOp, isFalse);
    expect(
      identical(first, second),
      isFalse,
      reason: 'A fully released claim must not be handed back out.',
    );

    // Release is idempotent: shutdown paths call it defensively, and an
    // extra call must not steal the claim a later opener now holds.
    await first.release();
    expect(second.holders, 1);
  });

  test('two databases in different folders do not contend', () async {
    final otherDir = await Directory(p.join(tempDir.path, 'other')).create();
    final otherDb = File(p.join(otherDir.path, 'skotiq.db'));

    final a = await SingleInstanceLock.acquire(dbFile);
    addTearDown(a.release);
    final b = await SingleInstanceLock.acquire(otherDb);
    addTearDown(b.release);

    expect(a.lockPath, isNot(equals(b.lockPath)));
  });

  test('the escape hatch disables the guard entirely', () async {
    final first = await SingleInstanceLock.acquire(dbFile);
    addTearDown(first.release);

    final second = await SingleInstanceLock.acquire(
      dbFile,
      environment: const {skotiqAllowMultipleInstancesEnv: '1'},
    );
    addTearDown(second.release);

    expect(second.isNoOp, isTrue);
  });

  test(
    'acquire creates the database folder if it does not exist yet',
    () async {
      final nested = File(p.join(tempDir.path, 'deep', 'nested', 'ns.db'));
      final lock = await SingleInstanceLock.acquire(nested);
      addTearDown(lock.release);

      expect(await nested.parent.exists(), isTrue);
    },
  );

  group('cross-process', () {
    // POSIX record locks are granted unconditionally to the process that
    // already owns them, so proving the guard really works requires a
    // *separate* process to hold the lock. python3's `fcntl.lockf` uses the
    // same F_SETLK record-lock space as Dart's RandomAccessFile.lock, so it
    // is a faithful stand-in for a second Skotiq.
    test('a lock held by another process blocks acquisition', () async {
      if (Platform.isWindows) {
        markTestSkipped('POSIX record locks');
        return;
      }
      final probe = await Process.run('python3', ['-c', 'import fcntl']);
      if (probe.exitCode != 0) {
        markTestSkipped('python3 with fcntl is not available');
        return;
      }

      final lockPath = SingleInstanceLock.lockPathFor(dbFile);
      await File(lockPath).writeAsString('pid=424242\n', flush: true);

      final holder = await Process.start('python3', [
        '-c',
        'import fcntl, sys, time\n'
            'f = open(sys.argv[1], "r+b")\n'
            'fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)\n'
            'sys.stdout.write("locked\\n")\n'
            'sys.stdout.flush()\n'
            'time.sleep(60)\n',
        lockPath,
      ]);
      addTearDown(() => holder.kill());

      // Wait until the child confirms it owns the lock, so the assertion
      // below cannot pass for the wrong reason (a race, not the guard).
      final ready = await holder.stdout
          .transform(const SystemEncoding().decoder)
          .firstWhere((chunk) => chunk.contains('locked'))
          .timeout(const Duration(seconds: 10), onTimeout: () => '');
      expect(ready, contains('locked'), reason: 'holder never took the lock');

      await expectLater(
        SingleInstanceLock.acquire(dbFile),
        throwsA(
          isA<SkotiqAlreadyRunningException>().having(
            (e) => e.holderPid,
            'holderPid read from the lockfile',
            424242,
          ),
        ),
      );

      // And the database was left alone.
      expect(await dbFile.exists(), isFalse);

      holder.kill();
      await holder.exitCode;

      // Once the other process is gone the lock is free again — the kernel
      // drops it on exit, so there is no stale lock to clean up.
      final lock = await SingleInstanceLock.acquire(dbFile);
      addTearDown(lock.release);
      expect(lock.isNoOp, isFalse);
    });
  });
}
