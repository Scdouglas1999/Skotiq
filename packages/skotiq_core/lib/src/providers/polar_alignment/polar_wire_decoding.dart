part of '../polar_alignment_provider.dart';

/// Coerce a wire value (int/double/numeric-string) to an `int`, else null.
int? _wireInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// Coerce a wire value (int/double/numeric-string) to a `double`, else null.
/// JSON collapses whole numbers to `int`, so a blind `as double?` cast throws.
double? _wireDoubleOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// Decode a polar-alignment image payload into raw JPEG bytes.
///
/// Accepts the three shapes the payload can take on the wire:
///  * `Uint8List` / `List<int>` — local FFI path,
///  * `List` of numeric elements — JSON array over the network,
///  * base64 `String` — some transports encode bytes as text.
///
/// Throws [FormatException] for a missing or structurally-invalid payload so
/// the caller can ignore it safely instead of crashing the event stream.
Uint8List _decodeImageBytes(Object? raw) {
  if (raw == null) {
    throw const FormatException('polar image payload is null');
  }
  if (raw is Uint8List) return raw;
  if (raw is List<int>) return Uint8List.fromList(raw);
  if (raw is List) {
    final out = Uint8List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      final element = raw[i];
      if (element is! num) {
        throw FormatException(
          'polar image byte at $i is ${element.runtimeType}, not a number',
        );
      }
      final v = element.toInt();
      if (v < 0 || v > 255) {
        throw FormatException('polar image byte at $i out of range: $v');
      }
      out[i] = v;
    }
    return out;
  }
  if (raw is String) {
    try {
      return base64Decode(raw);
    } catch (e) {
      throw FormatException('polar image string is not valid base64: $e');
    }
  }
  throw FormatException(
    'unsupported polar image payload type: ${raw.runtimeType}',
  );
}
