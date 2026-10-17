import 'dart:convert';
import 'dart:developer' as developer;

Map<String, dynamic> decodeJsonObjectString(
  String jsonStr, {
  required String context,
}) {
  final decoded = jsonDecode(jsonStr);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('$context must be a JSON object');
  }
  return decoded;
}

List<String> decodeStringListJson(String? jsonStr, {required String context}) {
  if (jsonStr == null || jsonStr.trim().isEmpty) return const [];
  final decoded = jsonDecode(jsonStr);
  if (decoded is! List) {
    throw FormatException('$context must be a JSON array');
  }

  return decoded
      .map((value) {
        if (value is! String) {
          throw FormatException('$context entries must be strings');
        }
        final normalized = value.trim();
        if (normalized.isEmpty) {
          throw FormatException('$context entries must not be empty');
        }
        return normalized;
      })
      .toList(growable: false);
}

Map<String, int> decodeStringIntMapJson(
  String? jsonStr, {
  required String context,
}) {
  if (jsonStr == null || jsonStr.trim().isEmpty) return const {};
  final decoded = jsonDecode(jsonStr);
  if (decoded is! Map) {
    throw FormatException('$context must be a JSON object');
  }

  final result = <String, int>{};
  for (final entry in decoded.entries) {
    final key = entry.key;
    if (key is! String) {
      throw FormatException('$context keys must be strings');
    }

    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty) {
      throw FormatException('$context keys must not be empty');
    }

    final value = entry.value;
    if (value is! num) {
      throw FormatException('$context values must be numeric');
    }
    result[normalizedKey] = value.toInt();
  }
  return result;
}

int? jsonInt(dynamic value, {required String context}) {
  if (value == null) return null;
  if (value is! num) {
    throw FormatException('$context must be numeric');
  }
  return value.toInt();
}

double? jsonDouble(dynamic value, {required String context}) {
  if (value == null) return null;
  if (value is! num) {
    throw FormatException('$context must be numeric');
  }
  return value.toDouble();
}

String? jsonString(
  dynamic value, {
  required String context,
  bool allowEmpty = true,
}) {
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$context must be a string');
  }
  final normalized = value.trim();
  if (!allowEmpty && normalized.isEmpty) {
    throw FormatException('$context must not be empty');
  }
  return normalized;
}

DateTime? jsonDateTime(dynamic value, {required String context}) {
  final normalized = jsonString(value, context: context, allowEmpty: false);
  if (normalized == null) return null;
  return DateTime.parse(normalized);
}

void logJsonWarning(String context, Object error, [StackTrace? stackTrace]) {
  developer.log(
    '$context: $error',
    name: 'JsonValidation',
    level: 900,
    error: error,
    stackTrace: stackTrace,
  );
}
