// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'weather_settings_dao.dart';

// ignore_for_file: type=lint
mixin _$WeatherSettingsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $WeatherSettingsTable get weatherSettings => attachedDatabase.weatherSettings;
  WeatherSettingsDaoManager get managers => WeatherSettingsDaoManager(this);
}

class WeatherSettingsDaoManager {
  final _$WeatherSettingsDaoMixin _db;
  WeatherSettingsDaoManager(this._db);
  $$WeatherSettingsTableTableManager get weatherSettings =>
      $$WeatherSettingsTableTableManager(
        _db.attachedDatabase,
        _db.weatherSettings,
      );
}
