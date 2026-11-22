// The app's device-id grammar against the shared cases in
// test_fixtures/device_id/cases.json, which also record what the bridge's
// ParsedDeviceId makes of each id (bridge/src/device_id/fixture_tests.rs).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/utils.dart';

void main() {
  final cases =
      (jsonDecode(
                File(
                  '../../test_fixtures/device_id/cases.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();

  test('the fixture has cases', () => expect(cases, isNotEmpty));

  for (final testCase in cases) {
    final id = testCase['id'] as String;
    final expected = testCase['dart'] as Map<String, dynamic>;
    test('device id ${jsonEncode(id)}', () {
      final parsed = DeviceId.parse(id);
      expect(parsed.kind.name, expected['kind']);
      expect(parsed.canonical, expected['canonical']);
      expect(isValidDeviceIdFormat(id), expected['valid']);
      expect(friendlyNameFromDeviceId(id), expected['friendlyName']);
    });
  }
}
