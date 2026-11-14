/// Strict readers for the fields of a decoded JSON object. Each throws a
/// [FormatException] that names the row and the field, so a response from a
/// host with a different idea of the shape fails where it is read instead of
/// surfacing later as a null or a wrong number.
library;

import 'wire_time.dart';

int requiredInt(
  Map<String, dynamic> json,
  String key,
  String context, {
  required int min,
}) {
  if (!json.containsKey(key)) {
    throw FormatException('$context is missing $key');
  }
  final value = json[key];
  if (value is! num || !value.isFinite || value != value.truncateToDouble()) {
    throw FormatException('$context.$key must be an integer');
  }
  final result = value.toInt();
  if (result < min) {
    throw FormatException('$context.$key must be at least $min');
  }
  return result;
}

String requiredString(
  Map<String, dynamic> json,
  String key,
  String context, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('$context.$key must be a valid string');
  }
  return value;
}

String? optionalString(
  Map<String, dynamic> json,
  String key,
  String context, {
  bool allowEmpty = false,
}) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return requiredString(json, key, context, allowEmpty: allowEmpty);
}

bool requiredBool(Map<String, dynamic> json, String key, String context) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('$context.$key must be a boolean');
  }
  return value;
}

List<String> requiredStringList(
  Map<String, dynamic> json,
  String key,
  String context,
) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('$context.$key must be a string array');
  }
  final result = <String>[];
  for (var index = 0; index < value.length; index++) {
    final item = value[index];
    if (item is! String || item.trim().isEmpty) {
      throw FormatException('$context.$key[$index] must be a non-empty string');
    }
    result.add(item);
  }
  return List.unmodifiable(result);
}

DateTime requiredDate(Map<String, dynamic> json, String key, String context) {
  final parsed = tryParseWireTime(requiredString(json, key, context));
  if (parsed == null) {
    throw FormatException('$context.$key is not a valid timestamp');
  }
  return parsed;
}

/// The instant a row carries twice: as a wire time under [key] and as epoch
/// milliseconds under [msKey]. The milliseconds are the instant. The wire
/// time must name the same one, except from a host that sent its local time
/// with no offset: that string names the instant only in the host's own time
/// zone, so it is not held against the milliseconds.
DateTime requiredInstant(
  Map<String, dynamic> json,
  String key,
  String msKey,
  String context,
) {
  final raw = requiredString(json, key, context);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw FormatException('$context.$key is not a valid timestamp');
  }
  final ms = requiredInt(json, msKey, context, min: 1);
  if (parsed.isUtc && parsed.millisecondsSinceEpoch != ms) {
    throw FormatException('$context $key and $msKey disagree');
  }
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

DateTime? optionalDate(Map<String, dynamic> json, String key, String context) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return requiredDate(json, key, context);
}

int? optionalInt(
  Map<String, dynamic> json,
  String key,
  String context, {
  required int min,
}) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return requiredInt(json, key, context, min: min);
}

double requiredDouble(
  Map<String, dynamic> json,
  String key,
  String context, {
  double? min,
}) {
  if (!json.containsKey(key)) {
    throw FormatException('$context is missing $key');
  }
  final value = json[key];
  if (value is! num || !value.isFinite || (min != null && value < min)) {
    throw FormatException('$context.$key must be a valid finite number');
  }
  return value.toDouble();
}

double? optionalDouble(
  Map<String, dynamic> json,
  String key,
  String context, {
  double? min,
}) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return requiredDouble(json, key, context, min: min);
}
