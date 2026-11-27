import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart' as models;
import 'package:skotiq_core/src/settings/app_settings_codec.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';
import 'package:skotiq_core/src/settings/app_settings_table.dart';
import 'package:skotiq_core/src/settings/setting.dart';

/// A value of [setting] other than its default, as the setting holds it.
Object? _changed(Setting<Object?> setting) => switch (setting) {
  BoolSetting(:final fallback) => !fallback,
  OptionalBoolSetting(:final fallback) => !(fallback ?? false),
  IntSetting(:final fallback) => setting.clean(fallback + 1),
  OptionalIntSetting(:final fallback) => (fallback ?? 0) + 1,
  DoubleSetting(:final fallback) => setting.clean(fallback + 0.5),
  OptionalDoubleSetting(:final fallback) => (fallback ?? 0) + 0.5,
  TextSetting(:final allowed?, :final fallback) => allowed.firstWhere(
    (value) => value != fallback,
  ),
  TextSetting(:final fallback) =>
    ['$fallback-changed', 'XISF', 'camera', 'zstd+sh']
        .map(setting.clean)
        .firstWhere((value) => value != fallback, orElse: () => fallback),
  OptionalTextSetting() => 'changed',
  EnumSetting(:final values, :final fallback) => values.firstWhere(
    (value) => value != fallback,
  ),
  BoolMapSetting() => const {'Ha': true},
  DoubleMapSetting() => const {'cloud': 0.75},
};

void main() {
  final hostSettings = [
    for (final setting in kAppSettingsTable)
      if (setting.sync == SettingSync.host) setting,
  ];

  test('the document has a field for every host setting', () {
    final keys = const models.AppSettings().toJson().keys.toSet();
    expect([
      for (final setting in hostSettings)
        if (!keys.contains(setting.wire)) setting.wire,
    ], isEmpty);
  });

  test('a setting held natively travels as the store holding it says', () {
    for (final setting in hostSettings.where((s) => s.heldNatively)) {
      final value = setting.toJson(_changed(setting));
      final sent = AppSettingsCodec.toWire(
        const AppSettingsState(),
        heldNatively: {setting.wire: value},
      ).toJson();
      expect(sent[setting.wire], value, reason: setting.wire);
      final previous = models.AppSettings.fromJson({setting.wire: value});
      expect(
        AppSettingsCodec.toWire(
          const AppSettingsState(),
          previous: previous,
        ).toJson()[setting.wire],
        value,
        reason: '${setting.wire} kept from the host snapshot',
      );
    }
  });

  test('every host setting survives a full snapshot from host to client', () {
    final lost = <String>[];
    final noOtherValue = <String>[];
    for (final setting in hostSettings.where((s) => !s.heldNatively)) {
      final value = _changed(setting);
      final host = const AppSettingsState().withValue(setting, value);
      if (setting.valuesEqual(host.valueOf(setting), setting.fallback)) {
        noOtherValue.add(setting.field);
        continue;
      }
      final sent =
          jsonDecode(jsonEncode(AppSettingsCodec.toWire(host).toJson()))
              as Map<String, dynamic>;
      final client = AppSettingsCodec.fromWire(
        models.AppSettings.fromJson(sent),
      );
      if (!setting.valuesEqual(
        client.valueOf(setting),
        host.valueOf(setting),
      )) {
        lost.add(setting.field);
      }
    }
    // Every capture is 16-bit today.
    expect(noOtherValue, ['bitDepth'], reason: 'settings without a test value');
    expect(lost, isEmpty);
  });
}
