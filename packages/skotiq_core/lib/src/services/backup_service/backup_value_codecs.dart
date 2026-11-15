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

/// A value of drift's JSON as the variable [column] stores.
Variable<Object> _jsonVariable(GeneratedColumn<Object> column, Object value) =>
    switch (column.type) {
      DriftSqlType.bool => Variable<bool>(value as bool),
      DriftSqlType.int => Variable<int>((value as num).toInt()),
      DriftSqlType.double => Variable<double>((value as num).toDouble()),
      DriftSqlType.dateTime =>
        _dateTimeValue(value).present
            ? Variable<DateTime>(_dateTimeValue(value).value)
            : throw FormatException('"${column.name}" is not a time: $value'),
      DriftSqlType.string => Variable<String>('$value'),
      _ => throw FormatException(
        '"${column.name}" holds a value this backup format cannot carry',
      ),
    };
