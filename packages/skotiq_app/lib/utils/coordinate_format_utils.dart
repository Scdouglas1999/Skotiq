import 'package:skotiq_core/skotiq_core.dart';

/// Coordinate formatting utilities for astronomical coordinates.
///
/// Provides consistent formatting for RA, Dec, altitude, azimuth, and FOV
/// across all planetarium and sky-related UI components.
class CoordinateFormatUtils {
  CoordinateFormatUtils._();

  /// Format Right Ascension (hours) as "Xh Ym Zs" with seconds.
  ///
  /// Example: 12.345 -> "12h 20m 42.0s"
  static String formatRA(double ra) => CoordinateFormat.ra(
        ra,
        style: SexagesimalStyle.plainLetters,
        wrapHours: true,
      );

  /// Format Right Ascension (hours) in compact form "Xh Ym" without seconds.
  ///
  /// Example: 12.345 -> "12h 20m"
  static String formatRACompact(double ra) => CoordinateFormat.raHm(
        ra,
        style: SexagesimalStyle.plainLetters,
        wrapHours: true,
      );

  /// Format Right Ascension (hours) in short form "Xh Ym Zs" with integer seconds.
  ///
  /// Example: 12.345 -> "12h 20m 42s"
  static String formatRAShort(double ra) => CoordinateFormat.ra(
        ra,
        style: SexagesimalStyle.plainLetters,
        seconds: SecondsPrecision.integerFloored,
        wrapHours: true,
      );

  /// Format Declination (degrees) as "+/-D\u00b0 M'".
  ///
  /// Example: -45.75 -> "-45\u00b0 45'"
  static String formatDec(double dec) =>
      CoordinateFormat.decDm(dec, style: SexagesimalStyle.plainLetters);

  /// Format Declination (degrees) in compact form "+/-D\u00b0".
  ///
  /// Example: -45.75 -> "-45\u00b0"
  static String formatDecCompact(double dec) {
    final sign = dec >= 0 ? '+' : '-';
    final d = dec.abs().floor();
    return "$sign$d\u00b0";
  }

  /// Format altitude (degrees) as "X.Y\u00b0".
  ///
  /// Example: 45.123 -> "45.1\u00b0"
  static String formatAltitude(double altitude, {int decimals = 1}) {
    return '${altitude.toStringAsFixed(decimals)}\u00b0';
  }

  /// Format azimuth (degrees) as "X.Y\u00b0".
  ///
  /// Example: 270.5 -> "270.5\u00b0"
  static String formatAzimuth(double azimuth, {int decimals = 1}) {
    return '${azimuth.toStringAsFixed(decimals)}\u00b0';
  }

  /// Format field of view (degrees) as "X.Y\u00b0".
  ///
  /// Example: 60.0 -> "60.0\u00b0"
  static String formatFOV(double fov, {int decimals = 1}) {
    return '${fov.toStringAsFixed(decimals)}\u00b0';
  }

}
