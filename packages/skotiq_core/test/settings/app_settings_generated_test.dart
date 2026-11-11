import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/settings/app_settings_table.dart';

import '../../tool/generate_app_settings.dart';

void main() {
  test('app_settings_state.g.dart matches the settings table', () {
    if (Platform.environment['SKOTIQ_REGENERATE'] == '1') {
      writeAppSettingsState();
    }
    final expected = generateAppSettingsState(
      File(kTablePath).readAsStringSync(),
    );
    expect(
      File(kGeneratedPath).readAsStringSync(),
      expected,
      reason:
          'The settings table changed. Regenerate with '
          'SKOTIQ_REGENERATE=1 flutter test '
          'test/settings/app_settings_generated_test.dart',
    );
  });

  test('every setting has its own field and its own rows', () {
    final fields = <String>{};
    final keys = <String>{};
    for (final setting in kAppSettingsTable) {
      expect(fields.add(setting.field), isTrue, reason: setting.field);
      for (final key in setting.keys) {
        expect(keys.add(key), isTrue, reason: key);
      }
    }
  });
}
