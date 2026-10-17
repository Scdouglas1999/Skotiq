import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/weather/weather_settings.dart';

/// Weather gating is opt-in (6.0.0): with no weather source or hardware safety
/// monitor configured (the out-of-box state), an enabled monitor fails closed
/// and aborts every automated sequence. These guard the fresh-install default.
void main() {
  test('WeatherSettings model defaults weather safety OFF', () {
    expect(const WeatherSettings().weatherSafetyEnabled, isFalse);
    expect(WeatherSettings.defaultSettings.weatherSafetyEnabled, isFalse);
  });

  test(
    'WeatherSettings.fromJson defaults weather safety OFF when key absent',
    () {
      expect(WeatherSettings.fromJson(const {}).weatherSafetyEnabled, isFalse);
      // An explicit opt-in still round-trips.
      expect(
        WeatherSettings.fromJson(const {
          'weatherSafetyEnabled': true,
        }).weatherSafetyEnabled,
        isTrue,
      );
    },
  );

  test('a fresh database seeds weather safety OFF', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    try {
      final row = await db.weatherSettingsDao.getOrCreateSettings();
      expect(
        row.weatherSafetyEnabled,
        isFalse,
        reason:
            'a brand-new install must not fail-closed-abort sequences '
            'before the user opts into weather gating',
      );
    } finally {
      await db.close();
    }
  });
}
