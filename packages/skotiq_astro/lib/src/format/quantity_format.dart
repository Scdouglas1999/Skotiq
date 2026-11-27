/// Plain numbers as text: trimmed decimals, grouped thousands, short counts,
/// percentages.
library;

abstract final class QuantityFormat {
  /// An exposure length to three significant digits, trailing zeros dropped:
  /// "300 s", "12.5 s", "2.5 s", "1.25 s", "0.25 s", and milliseconds below a
  /// tenth of a second ("5 ms", "0.032 ms"), so a short frame never reads
  /// "0 s". From 10 s it keeps one decimal ("300.5 s").
  /// [space] puts a space before "s" ("2.5 s") or not ("2.5s").
  static String exposure(double seconds, {bool space = true}) {
    if (seconds > 0 && seconds < 0.1) {
      final ms = seconds * 1000;
      return '${trimmed(ms, maxDecimals: _exposureDecimals(ms))} ms';
    }
    final value = trimmed(seconds, maxDecimals: _exposureDecimals(seconds));
    return '$value${space ? ' ' : ''}s';
  }

  static int _exposureDecimals(double value) {
    final magnitude = value.abs();
    if (magnitude >= 10) return 1;
    if (magnitude >= 1) return 2;
    return 3;
  }

  /// [value] with up to [maxDecimals] places and no trailing zeros: `30`,
  /// `2.5`, `0.25`. `-0` reads `0`.
  static String trimmed(double value, {int maxDecimals = 1}) {
    var text = value.toStringAsFixed(maxDecimals);
    if (text.contains('.')) {
      text = text
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    return text == '-0' ? '0' : text;
  }

  /// `12,345`.
  static String grouped(int value, {String separator = ','}) {
    final digits = value.abs().toString();
    final buffer = StringBuffer(value < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(separator);
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  /// A count short enough for a chip: `950`, `1.2k`, `3.4M`.
  static String compactCount(int value) {
    final magnitude = value.abs();
    if (magnitude < 1000) return '$value';
    if (magnitude < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '${(value / 1000000).toStringAsFixed(1)}M';
  }

  /// A value already in percent: `75%`, `12.5%`. A fraction that would print
  /// as `.0` is dropped.
  static String percent(double percent, {int maxDecimals = 1}) =>
      '${trimmed(percent, maxDecimals: maxDecimals)}%';

  /// A 0..1 fraction as a percentage: `0.125` -> `12.5%`.
  static String fraction(double fraction, {int maxDecimals = 1}) =>
      percent(fraction * 100, maxDecimals: maxDecimals);
}
