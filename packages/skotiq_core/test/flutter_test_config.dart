import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Global test harness setup, auto-loaded by `flutter test` for every test in
/// this package.
///
/// Many services/providers resolve the on-disk database path via
/// `path_provider` (`getApplicationDocumentsDirectory`), which has no platform
/// implementation under `flutter test`. Without a stub these tests throw
/// `MissingPluginException` / "Binding has not yet been initialized" the moment
/// a provider touches the database. We point path_provider at a temp directory
/// so tests that don't override `databaseProvider` still run against a
/// throwaway on-disk SQLite file. Individual tests may still override
/// `databaseProvider` with an in-memory DB for full isolation.
///
/// A provider can start opening that database and the test end before the
/// open has finished: nothing awaits it, and disposing the container does not
/// wait for it either. So the open must never meet another test's connection
/// or a deleted directory:
///   * each test gets its own directory under the file's scratch directory,
///     so a slow open from one test never holds the file the next test's
///     start-up check reads;
///   * the scratch directory is not deleted when the file's tests end, when
///     the last test's open may still be running. The next test process to
///     start deletes the scratch directories whose process has exited.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TestWidgetsFlutterBinding installs an HttpOverrides that fakes every HTTP
  // request (returns 400, no real socket). Several backend tests start a real
  // local HttpServer and connect to it over real sockets, so restore the real
  // dart:io HttpClient. Tests that want to fake HTTP can still install their own
  // HttpOverrides locally.
  HttpOverrides.global = null;

  _deleteScratchOfExitedProcesses();
  final scratch = await Directory.systemTemp.createTemp('$_scratchPrefix$pid-');

  // What path_provider answers: the scratch directory while a file's
  // `setUpAll` runs, then one directory per test.
  var current = scratch;
  var testNumber = 0;
  setUp(() {
    current = Directory('${scratch.path}/t${++testNumber}')..createSync();
  });

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProviderChannel, (call) async {
        return current.path;
      });

  await testMain();
}

const _scratchPrefix = 'skotiq-core-test-';

/// Deletes the scratch directories of test processes that are gone. A
/// directory names the process that made it; one without a readable process
/// id, or on a platform without `/proc`, goes once it is a day old.
void _deleteScratchOfExitedProcesses() {
  final List<FileSystemEntity> entries;
  try {
    entries = Directory.systemTemp.listSync(followLinks: false);
  } on FileSystemException {
    return;
  }
  final dayAgo = DateTime.now().subtract(const Duration(days: 1));
  final hasProc = Directory('/proc/$pid').existsSync();
  for (final entry in entries) {
    if (entry is! Directory) continue;
    final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (!name.startsWith(_scratchPrefix)) continue;
    final owner = int.tryParse(
      name.substring(_scratchPrefix.length).split('-').first,
    );
    try {
      final exited = owner != null && hasProc
          ? !Directory('/proc/$owner').existsSync()
          : entry.statSync().modified.isBefore(dayAgo);
      if (exited) entry.deleteSync(recursive: true);
    } on FileSystemException {
      // Another test process is deleting the same directory.
    }
  }
}
