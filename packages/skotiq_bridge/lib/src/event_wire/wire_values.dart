import 'dart:convert';
import 'dart:typed_data';

/// Readers for the fields of a wire map (an event's data, a JSON object).
/// A text or fractional field that is absent reads as empty or zero; a count
/// that is absent is a [FormatException], because no count can stand in for
/// it.

String wireString(Map<String, Object?> data, String key) {
  final value = data[key];
  return value is String ? value : '';
}

String? wireOptString(Map<String, Object?> data, String key) {
  final value = data[key];
  return value is String ? value : null;
}

int wireInt(Map<String, Object?> data, String key) {
  final value = wireOptInt(data, key);
  if (value == null) {
    throw FormatException('Missing required int field "$key"');
  }
  return value;
}

int? wireOptInt(Map<String, Object?> data, String key) {
  final value = data[key];
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  if (value is BigInt) return value.toInt();
  return null;
}

BigInt wireBigInt(Map<String, Object?> data, String key) =>
    BigInt.from(wireInt(data, key));

BigInt? wireOptBigInt(Map<String, Object?> data, String key) {
  final value = wireOptInt(data, key);
  return value == null ? null : BigInt.from(value);
}

double wireDouble(Map<String, Object?> data, String key) =>
    wireOptDouble(data, key) ?? 0.0;

double? wireOptDouble(Map<String, Object?> data, String key) {
  final value = data[key];
  return value is num ? value.toDouble() : null;
}

bool wireBool(Map<String, Object?> data, String key) => data[key] == true;

bool? wireOptBool(Map<String, Object?> data, String key) {
  final value = data[key];
  return value is bool ? value : null;
}

List<String> wireStringList(Map<String, Object?> data, String key) =>
    wireOptStringList(data, key) ?? const [];

List<String>? wireOptStringList(Map<String, Object?> data, String key) {
  final value = data[key];
  if (value is! List) return null;
  return value.whereType<String>().toList(growable: false);
}

/// [raw] as a string-keyed map; empty when it is not a map.
Map<String, Object?> wireMap(Object? raw) {
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}

List<Map<String, Object?>> wireMapList(Map<String, Object?> data, String key) {
  final value = data[key];
  if (value is! List) return const [];
  return [
    for (final entry in value)
      if (entry is Map) wireMap(entry),
  ];
}

/// Bytes as the host holds them, as a JSON list, or as base64 text.
Uint8List wireBytes(Map<String, Object?> data, String key) {
  final value = data[key];
  if (value is Uint8List) return value;
  if (value is List) return Uint8List.fromList(value.whereType<int>().toList());
  if (value is String) {
    try {
      return base64Decode(value);
    } on FormatException {
      return Uint8List(0);
    }
  }
  return Uint8List(0);
}

/// [value], or a [FormatException] naming the field it was read from.
T wireRequired<T>(T? value, String key) {
  if (value == null) {
    throw FormatException('Missing or unknown value for field "$key"');
  }
  return value;
}
