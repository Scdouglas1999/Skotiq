import 'dart:developer' as developer;

import 'coordinate_format.dart';

/// Utility class for parsing astronomical coordinates in various formats
class CoordinateParser {
  /// Parse RA string to hours (decimal)
  /// Supports formats:
  /// - HH:MM:SS.ss or HH:MM:SS
  /// - HHhMMmSSs or HH MM SS
  /// - Decimal hours (e.g., 12.5)
  /// - Decimal degrees if value > 24 (heuristic) or explicitly suffixed (deg, d, °)
  ///
  /// Returns null if parsing fails or value is out of range.
  static double? parseRa(String input) {
    if (input.trim().isEmpty) return null;

    final trimmed = input.trim();
    final lower = trimmed.toLowerCase();

    // Explicit degrees suffix (common copy/paste format)
    if (lower.endsWith('deg') || lower.endsWith('°') || lower.endsWith('d')) {
      var degText = lower;
      if (degText.endsWith('deg')) {
        degText = degText.substring(0, degText.length - 3).trim();
      } else {
        // remove trailing '°' or 'd'
        degText = degText.substring(0, degText.length - 1).trim();
      }
      final deg = double.tryParse(degText);
      if (deg != null && deg.isFinite && deg >= 0 && deg <= 360) {
        return (deg % 360) / 15.0;
      }
      return null;
    }

    // Try decimal format first
    final decimal = double.tryParse(trimmed);
    if (decimal != null && decimal.isFinite) {
      if (decimal >= 0 && decimal < 24) {
        return decimal;
      }
      // Heuristic: if value looks like degrees, convert to hours.
      if (decimal > 24 && decimal <= 360) {
        return (decimal % 360) / 15.0;
      }
      return null;
    }

    // Remove common separators and letters
    final cleaned = lower
        .replaceAll('h', ':')
        .replaceAll('m', ':')
        .replaceAll('s', '')
        .replaceAll(' ', ':')
        .replaceAll(RegExp(r':+'), ':')
        .replaceAll(RegExp(r'^:|:$'), '');

    final parts = cleaned.split(':');
    if (parts.isEmpty || parts.length > 3) return null;

    try {
      final hours = int.parse(parts[0]);
      final minutes = parts.length > 1 ? int.parse(parts[1]) : 0;
      final seconds = parts.length > 2 ? double.parse(parts[2]) : 0.0;

      if (hours < 0 || hours >= 24) return null;
      if (minutes < 0 || minutes >= 60) return null;
      if (seconds < 0 || seconds >= 60) return null;

      return hours + minutes / 60.0 + seconds / 3600.0;
    } catch (e, stackTrace) {
      // This is a user-input parser: `null` is the contract for any
      // unparseable string (the UI binds the field to "invalid RA" feedback),
      // and nothing throws across the validator boundary. FINE keeps a sudden
      // flood of parse failures visible in the dev console without spamming the
      // user-facing error pipeline.
      developer.log(
        'parseRa("$input") failed: $e\n$stackTrace',
        name: 'CoordinateParser',
        level: 500,
      );
      return null;
    }
  }

  /// Parse Dec string to degrees (decimal)
  /// Supports formats:
  /// - +DD:MM:SS.ss or -DD:MM:SS.ss
  /// - DD°MM'SS" or DD MM SS
  /// - Decimal degrees (e.g., +45.5 or -12.75)
  ///
  /// Returns null if parsing fails or value is out of range [-90, 90]
  static double? parseDec(String input) {
    if (input.trim().isEmpty) return null;

    final trimmed = input.trim();
    final lower = trimmed.toLowerCase();

    // Try decimal format first
    final decimal = double.tryParse(trimmed);
    if (decimal != null && decimal.isFinite) {
      if (decimal >= -90 && decimal <= 90) {
        return decimal;
      }
      return null;
    }

    // Determine sign
    final isNegative = lower.startsWith('-');
    final cleaned = lower
        .replaceAll('+', '')
        .replaceAll('-', '')
        .replaceAll('°', ':')
        .replaceAll('d', ':')
        .replaceAll('\'', ':')
        .replaceAll('m', ':')
        .replaceAll('"', '')
        .replaceAll('s', '')
        .replaceAll(' ', ':')
        .replaceAll(RegExp(r':+'), ':')
        .replaceAll(RegExp(r'^:|:$'), '');

    final parts = cleaned.split(':');
    if (parts.isEmpty || parts.length > 3) return null;

    try {
      final degrees = int.parse(parts[0]);
      final minutes = parts.length > 1 ? int.parse(parts[1]) : 0;
      final seconds = parts.length > 2 ? double.parse(parts[2]) : 0.0;

      if (degrees < 0 || degrees > 90) return null;
      if (minutes < 0 || minutes >= 60) return null;
      if (seconds < 0 || seconds >= 60) return null;

      final result = degrees + minutes / 60.0 + seconds / 3600.0;
      if (result > 90) return null;
      return isNegative ? -result : result;
    } catch (e, stackTrace) {
      // Why: user-input parser — see parseRa above. Returning `null` is the
      // contract for "unparseable Dec string"; the UI binds invalid input to
      // a validation message. Log at FINE for diagnostic visibility.
      developer.log(
        'parseDec("$input") failed: $e\n$stackTrace',
        name: 'CoordinateParser',
        level: 500,
      );
      return null;
    }
  }

  /// Hundredths of a second per hour/degree — the quantum
  /// [SecondsPrecision.twoDecimal] renders at, and therefore the resolution at
  /// which an RA can round up into a whole extra day.
  static const int _hundredthsPerUnit = 360000;

  /// Format RA from decimal hours to HMS string (HH:MM:SS.ss).
  ///
  /// [raHours] is folded into [0, 24) first, so 24h and negative inputs render
  /// as a real time of day rather than "24:00:00.00" or a negative hour.
  static String formatRaHms(double raHours) {
    if (raHours.isNaN || raHours.isInfinite) return '--:--:--.--';
    var wrapped = raHours % 24.0;
    if (wrapped < 0) wrapped += 24.0;
    // The rounding itself can push 23:59:59.999 up to a full 24h.
    if ((wrapped * _hundredthsPerUnit).round() >= 24 * _hundredthsPerUnit) {
      wrapped = 0.0;
    }
    return CoordinateFormat.ra(
      wrapped,
      style: SexagesimalStyle.paddedColons,
      seconds: SecondsPrecision.twoDecimal,
    );
  }

  /// Format Dec from decimal degrees to DMS string (+DD:MM:SS.ss)
  static String formatDecDms(double decDegrees) {
    if (decDegrees.isNaN || decDegrees.isInfinite) return '+--:--:--.--';
    return CoordinateFormat.dec(
      decDegrees,
      style: SexagesimalStyle.paddedColons,
      seconds: SecondsPrecision.twoDecimal,
    );
  }
}
