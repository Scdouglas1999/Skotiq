// The display name the app gives each id in the shared device-id cases
// (test_fixtures/device_id/cases.json).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/device_format_utils.dart';

void main() {
  final cases = (jsonDecode(
    File(
      '../../test_fixtures/device_id/cases.json',
    ).readAsStringSync(),
  ) as List)
      .cast<Map<String, dynamic>>();

  for (final testCase in cases) {
    final id = testCase['id'] as String;
    test('display name of ${jsonEncode(id)}', () {
      expect(
        formatDeviceId(id),
        (testCase['dart'] as Map<String, dynamic>)['displayName'],
      );
    });
  }
}
