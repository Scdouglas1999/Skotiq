import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart' as models;
import 'package:skotiq_core/src/settings/app_settings_codec.dart';
import 'package:skotiq_core/src/settings/app_settings_table.dart';
import 'package:skotiq_core/src/settings/setting.dart';

/// The wire model's defaults are what a host snapshot without a field reads
/// as. For a field a setting stands behind they must read as the setting's
/// own default, or the two copies drift.
void main() {
  // An optional setting's wire field defaults to null, because an explicit
  // null ("do not apply this check") must stay expressible on the wire; a
  // wire default would replace it. Absent, these read as "off" while a fresh
  // install starts them on.
  const absentReadsOff = {
    'imageGradingHfrBaselinePercent',
    'imageGradingEccentricityBaselinePercent',
    'imageGradingStarCountDropPercent',
  };

  test('a snapshot without a field reads as the table default', () {
    final state = AppSettingsCodec.fromWire(const models.AppSettings());
    final drift = <String>{};
    for (final setting in kAppSettingsTable) {
      if (setting.sync != SettingSync.host) continue;
      final read = jsonEncode(setting.toJson(state.valueOf(setting)));
      if (read != jsonEncode(setting.toJson(setting.fallback))) {
        drift.add(setting.wire);
      }
    }
    expect(drift, absentReadsOff);
  });
}
