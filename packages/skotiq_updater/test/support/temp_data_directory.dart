import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A data directory for a test that builds an updater service without caring
/// where it keeps its state. Created on first use and removed when the test
/// ends. Call from inside a test or `setUp`.
Future<Directory> Function() tempDataDirectory() {
  Directory? dir;
  addTearDown(() {
    final created = dir;
    if (created != null && created.existsSync()) {
      created.deleteSync(recursive: true);
    }
  });
  return () async =>
      dir ??= await Directory.systemTemp.createTemp('skotiq_updater_test_');
}
