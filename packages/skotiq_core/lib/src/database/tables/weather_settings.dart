import 'package:drift/drift.dart';

/// Weather settings table - stores user preferences for weather radar and safety
@DataClassName('WeatherSettingRow')
class WeatherSettings extends Table {
  IntColumn get id => integer().autoIncrement()();
  RealColumn get triggerDistanceKm =>
      real().withDefault(const Constant(30.0))();
  RealColumn get cloudDensityThreshold =>
      real().withDefault(const Constant(60.0))();
  IntColumn get leadTimeMinutes => integer().withDefault(const Constant(15))();
  BoolColumn get weatherSafetyEnabled =>
      boolean().withDefault(const Constant(true))();
  RealColumn get maxHumidityPercent =>
      real().withDefault(const Constant(90.0))();
  RealColumn get maxWindSpeedKph => real().withDefault(const Constant(30.0))();
  RealColumn get maxCloudCoverPercent =>
      real().withDefault(const Constant(80.0))();
  BoolColumn get autoParkEnabled =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get autoResumeEnabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get preferredProvider =>
      text().withDefault(const Constant('auto'))();
  IntColumn get refreshIntervalSeconds =>
      integer().withDefault(const Constant(300))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
