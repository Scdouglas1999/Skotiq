import 'dart:io';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

void main() {
  test('the hub reports the release its pubspec names', () {
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())?.group(1);
    expect(hubVersion, version);
  });
}
