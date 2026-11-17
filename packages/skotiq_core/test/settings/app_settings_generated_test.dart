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

  // `dart run tool/generate_app_settings.dart` crashed inside the compiler
  // ("InvalidType is not a subtype of FunctionType") because the table
  // imported the remote-protocol barrel, which pulls in Flutter.
  test(
    'the generator runs under plain Dart',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tool/generate_app_settings.dart',
        '--check',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

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
