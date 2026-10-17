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
/// a provider touches the database. We point path_provider at a per-isolate temp
/// directory so tests that don't override `databaseProvider` still run against a
/// throwaway on-disk SQLite file. Individual tests may still override
/// `databaseProvider` with an in-memory DB for full isolation.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TestWidgetsFlutterBinding installs an HttpOverrides that fakes every HTTP
  // request (returns 400, no real socket). Several backend tests start a real
  // local HttpServer and connect to it over real sockets, so restore the real
  // dart:io HttpClient. Tests that want to fake HTTP can still install their own
  // HttpOverrides locally.
  HttpOverrides.global = null;

  final tempDir = await Directory.systemTemp.createTemp('skotiq-core-test-');

  // Delete the scratch dir once every test in this file has run. `tearDownAll`
  // rather than a delete after `testMain()`: `testMain` only *registers* the
  // tests, so deleting there would pull the directory out from under them. It
  // also runs when a test fails, which is exactly when this used to leak — the
  // dirs accumulated one per test isolate and never came back.
  tearDownAll(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProviderChannel, (call) async {
        // Every path_provider query resolves to the throwaway temp dir.
        return tempDir.path;
      });

  await testMain();
}
