// JSON helpers for runtime channel values. Kept out of the package barrel so
// their short names do not collide with app code.

/// Finite doubles only: JSON has no NaN or infinity.
double? finiteOrNull(num? value) {
  if (value == null) return null;
  final d = value.toDouble();
  return d.isFinite ? d : null;
}

double? jsonDouble(Object? value) => value is num ? value.toDouble() : null;

/// A field every value of a channel carries. A missing or mistyped one means
/// the two ends disagree about the channel, and the update is dropped rather
/// than shown with an invented number.
double requireDouble(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  throw FormatException('Runtime value has no number "$key"');
}

int requireInt(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toInt();
  throw FormatException('Runtime value has no integer "$key"');
}

int? jsonInt(Object? value) => value is num ? value.toInt() : null;

String? jsonString(Object? value) => value is String ? value : null;

DateTime? jsonInstant(Object? value) => value is num
    ? DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true)
    : null;
