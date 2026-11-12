// UTC-offset timezone tables and site-angle parsing helpers.
part of '../location_settings.dart';

/// Timezone values the app can actually honour.
///
/// `clockProvider` builds its [FixedOffsetClock] from these labels, so every
/// entry here changes the clock when "Use system time" is off. Offsets rather
/// than IANA zones because Skotiq carries no timezone database: a city name
/// it cannot resolve makes the picker inert.
const List<String> kUtcOffsetTimezones = [
  'UTC-12:00',
  'UTC-11:00',
  'UTC-10:00',
  'UTC-09:30',
  'UTC-09:00',
  'UTC-08:00',
  'UTC-07:00',
  'UTC-06:00',
  'UTC-05:00',
  'UTC-04:00',
  'UTC-03:30',
  'UTC-03:00',
  'UTC-02:00',
  'UTC-01:00',
  'UTC',
  'UTC+01:00',
  'UTC+02:00',
  'UTC+03:00',
  'UTC+03:30',
  'UTC+04:00',
  'UTC+04:30',
  'UTC+05:00',
  'UTC+05:30',
  'UTC+05:45',
  'UTC+06:00',
  'UTC+06:30',
  'UTC+07:00',
  'UTC+08:00',
  'UTC+08:45',
  'UTC+09:00',
  'UTC+09:30',
  'UTC+10:00',
  'UTC+10:30',
  'UTC+11:00',
  'UTC+12:00',
  'UTC+12:45',
  'UTC+13:00',
  'UTC+14:00',
];

/// Standard-time offset for each IANA label the previous picker could store.
/// Standard, not summer, time: a fixed offset cannot follow a DST rule, so a
/// summer-time value would be wrong for half the year.
const Map<String, String> kLegacyIanaUtcOffsets = {
  'America/New_York': 'UTC-05:00',
  'America/Chicago': 'UTC-06:00',
  'America/Denver': 'UTC-07:00',
  'America/Los_Angeles': 'UTC-08:00',
  'America/Phoenix': 'UTC-07:00',
  'America/Anchorage': 'UTC-09:00',
  'Pacific/Honolulu': 'UTC-10:00',
  'Europe/London': 'UTC',
  'Europe/Paris': 'UTC+01:00',
  'Europe/Berlin': 'UTC+01:00',
  'Europe/Moscow': 'UTC+03:00',
  'Asia/Tokyo': 'UTC+09:00',
  'Asia/Shanghai': 'UTC+08:00',
  'Asia/Kolkata': 'UTC+05:30',
  'Australia/Sydney': 'UTC+10:00',
  'Australia/Perth': 'UTC+08:00',
  'Pacific/Auckland': 'UTC+12:00',
};

/// The offset entry a stored timezone label should select in the picker.
String utcOffsetForTimezone(String stored) {
  if (kUtcOffsetTimezones.contains(stored)) return stored;
  return kLegacyIanaUtcOffsets[stored] ?? 'UTC';
}
