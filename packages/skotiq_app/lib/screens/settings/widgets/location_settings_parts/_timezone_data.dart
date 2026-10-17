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

/// Read a site latitude or longitude written the way coordinates are normally
/// quoted, and return it in decimal degrees.
///
/// Accepted, for [positiveHemisphere]/[negativeHemisphere] = N/S or E/W:
///   `44.0582`  `-121.3153`  `44.0582 N`  `44 3 29 N`  `44° 3' 29" N`
///   `44d03m29s`  `N 44 03 29`  `121 18 55 W`
///
/// Returns `null` for invalid or out-of-range input rather than clamping it.
double? parseSiteAngle(
  String input, {
  required double maxDegrees,
  required String positiveHemisphere,
  required String negativeHemisphere,
}) {
  var text = input.trim();
  if (text.isEmpty) return null;

  // `s` is BOTH the South hemisphere and the seconds unit. The two spellings
  // are told apart by whether the string uses the other unit letters: in
  // `44d03m29s` the trailing s closes a d/m/s triple, while in `44 03 29 S` it
  // is a hemisphere. Nothing else is ambiguous — n/e/w are never units.
  final usesUnitLetters = RegExp(r'\d\s*[dm]', caseSensitive: false)
      .hasMatch(text.replaceAll(RegExp('[^0-9a-zA-Z ]'), ''));

  // ...and, when they are, by whether the trailing letter is GLUED to a digit.
  // `44d03m29s` closes a triple; `44d03m29s S` says South after it, and
  // reading that as a second seconds marker put the site 88 degrees away in
  // the wrong hemisphere without saying so.
  final lowered = input.trim().toLowerCase();
  final trailingLetterFollowsDigit = lowered.length >= 2 &&
      RegExp(r'\d').hasMatch(lowered[lowered.length - 2]);

  bool? negativeHemisphereSeen;
  for (final (letter, isNegative) in [
    (positiveHemisphere, false),
    (negativeHemisphere, true),
  ]) {
    final ambiguousSeconds = usesUnitLetters &&
        letter.toLowerCase() == 's' &&
        trailingLetterFollowsDigit;
    if (text.toLowerCase().startsWith(letter.toLowerCase())) {
      text = text.substring(letter.length).trim();
      negativeHemisphereSeen = isNegative;
      break;
    }
    if (!ambiguousSeconds &&
        text.toLowerCase().endsWith(letter.toLowerCase())) {
      text = text.substring(0, text.length - letter.length).trim();
      negativeHemisphereSeen = isNegative;
      break;
    }
  }
  if (text.isEmpty) return null;

  final explicitlyNegative = text.startsWith('-');
  // "-44 S" says south twice, or north-and-south; either way the operator and
  // the app would disagree about which hemisphere was stored.
  if (explicitlyNegative && negativeHemisphereSeen != null) return null;
  if (explicitlyNegative || text.startsWith('+')) {
    text = text.substring(1).trim();
  }

  // Everything that separates the three components — degree/minute/second
  // marks, unit letters, colons, commas — becomes whitespace, leaving numbers.
  final normalized = text
      .replaceAll(RegExp("[°º:,dhmsʹʺ'′″\"]", caseSensitive: false), ' ')
      .trim();
  if (normalized.isEmpty) return null;
  final parts = normalized.split(RegExp(r'\s+'));
  if (parts.length > 3) return null;

  var magnitude = 0.0;
  for (var i = 0; i < parts.length; i++) {
    final value = double.tryParse(parts[i]);
    if (value == null || !value.isFinite || value < 0) return null;
    // Only the last component may be fractional: "44 3.5 29" is not a
    // coordinate anyone writes, and reading it would be guesswork.
    if (i < parts.length - 1 && value != value.roundToDouble()) return null;
    if (i > 0 && value >= 60) return null;
    magnitude += value / [1.0, 60.0, 3600.0][i];
  }

  if (magnitude > maxDegrees) return null;
  final negative = explicitlyNegative || (negativeHemisphereSeen ?? false);
  return negative ? -magnitude : magnitude;
}
