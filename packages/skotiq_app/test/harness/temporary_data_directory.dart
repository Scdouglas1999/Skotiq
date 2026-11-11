import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Points Skotiq's data and documents directories at a fresh temporary folder
/// for each test of the calling group, so code that falls back to them (no
/// image folder chosen) has somewhere to resolve without path_provider.
///
/// Returns a getter for the current test's folder.
Directory Function() useTemporaryDataDirectory() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sk_test_data_');
    debugResetSkotiqProcessEnvironment();
    captureSkotiqProcessEnvironment({skotiqDataDirEnv: directory.path});
  });
  tearDown(() async {
    debugResetSkotiqProcessEnvironment();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });
  return () => directory;
}
