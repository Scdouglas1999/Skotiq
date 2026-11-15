part of '../backup_service.dart';

String? _stringOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  return value.toString();
}

double? _doubleOrNull(Object? value) {
  return (value as num?)?.toDouble();
}

double _doubleOrDefault(Object? value, double fallback) {
  return (value as num?)?.toDouble() ?? fallback;
}

int? _intOrNull(Object? value) {
  return (value as num?)?.toInt();
}

int _intOrDefault(Object? value, int fallback) {
  return (value as num?)?.toInt() ?? fallback;
}

Value<DateTime> _dateTimeValue(Object? value) {
  if (value is DateTime) return Value(value);
  // Drift's JSON writes a time as milliseconds since the epoch.
  if (value is int) return Value(DateTime.fromMillisecondsSinceEpoch(value));
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return Value(parsed);
  }
  return const Value.absent();
}
