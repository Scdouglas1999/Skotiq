/// Right Ascension and Declination as sexagesimal text.
///
/// A coordinate takes one of three shapes on screen, and a caller names the
/// shape rather than assembling one from separators and precisions:
///
/// | shape   | RA              | Dec             | where                     |
/// |---------|-----------------|-----------------|---------------------------|
/// | readout | `05h 35m 17.3s` | `+22° 00' 52"`  | detail panels, dialogs    |
/// | dense   | `05h35m17s`     | `+22°00'52"`    | narrow grids, overlays    |
/// | compact | `05h35m`        | `+22°01'`       | rows, chips, summaries    |
///
/// UNITS: Right Ascension is taken in **decimal hours** unless the function
/// name ends in `FromDegrees`. One name covering both units is the confusion
/// that produces slews to the wrong place.
library;

/// Astronomical coordinate formatting (presentation only; `CoordinateParser`
/// reads every shape here back).
abstract final class CoordinateFormat {
  /// `05h 35m 17.3s`, folded into [0, 24).
  static String raReadout(double raHours) =>
      _ra(raHours, _Shape.spaced, secondDecimals: 1);

  /// [raReadout] for a value in decimal degrees.
  static String raReadoutFromDegrees(double raDegrees) =>
      raReadout(_hours(raDegrees));

  /// `+22° 00' 52"`.
  ///
  /// Whole arcseconds beside tenths of a second of time: the two then carry
  /// about the same precision on the sky (1" and 1.5").
  static String decReadout(double decDegrees) =>
      _dec(decDegrees, _Shape.spaced, secondDecimals: 0);

  /// `05h35m17s`, folded into [0, 24).
  static String raDense(double raHours) =>
      _ra(raHours, _Shape.dense, secondDecimals: 0);

  /// [raDense] for a value in decimal degrees.
  static String raDenseFromDegrees(double raDegrees) =>
      raDense(_hours(raDegrees));

  /// `+22°00'52"`.
  static String decDense(double decDegrees) =>
      _dec(decDegrees, _Shape.dense, secondDecimals: 0);

  /// `05h35m`, rounded to the minute and folded into [0, 24).
  static String raCompact(double raHours) =>
      _ra(raHours, _Shape.dense, secondDecimals: null);

  /// [raCompact] for a value in decimal degrees.
  static String raCompactFromDegrees(double raDegrees) =>
      raCompact(_hours(raDegrees));

  /// `+22°01'`, rounded to the arcminute.
  static String decCompact(double decDegrees) =>
      _dec(decDegrees, _Shape.dense, secondDecimals: null);


  /// What a non-finite coordinate reads as: unknown, never a made-up zero.
  static const String _unknown = '—';

  static double _hours(double raDegrees) => (raDegrees % 360.0) / 15.0;

  static String _ra(double raHours, _Shape shape, {int? secondDecimals}) {
    if (!raHours.isFinite) return _unknown;
    // Dart's `%` is non-negative for a positive divisor, so -0.005 h folds to
    // 23h59m rather than rendering as a negative hour.
    final perHour = _unitsPerWhole(secondDecimals);
    // The rounding itself can push 23:59:59.96 up into a 24th hour.
    final total = ((raHours % 24.0) * perHour).round() % (24 * perHour);
    return _join('', total, shape, secondDecimals, const ('h', 'm', 's'));
  }

  static String _dec(double decDegrees, _Shape shape, {int? secondDecimals}) {
    if (!decDegrees.isFinite) return _unknown;
    final total = (decDegrees.abs() * _unitsPerWhole(secondDecimals)).round();
    return _join(
      decDegrees >= 0 ? '+' : '-',
      total,
      shape,
      secondDecimals,
      const ('°', "'", '"'),
    );
  }

  /// How many of the smallest rendered unit make one hour or degree.
  static int _unitsPerWhole(int? secondDecimals) => switch (secondDecimals) {
    null => 60,
    0 => 3600,
    1 => 36000,
    _ => 360000,
  };

  /// Split [total] (the WHOLE angle, already rounded to the smallest rendered
  /// unit) into fields.
  ///
  /// Rounding the whole angle first is what keeps the carry structural:
  /// rounding the seconds field alone renders 5.6 h as `05h 35m 60.0s`, a time
  /// the parser refuses to read back.
  static String _join(
    String sign,
    int total,
    _Shape shape,
    int? secondDecimals,
    (String, String, String) glyphs,
  ) {
    String two(int v) => v.toString().padLeft(2, '0');
    final gap = shape == _Shape.spaced ? ' ' : '';
    if (secondDecimals == null) {
      final whole = two(total ~/ 60);
      final minutes = two(total % 60);
      return shape == _Shape.colons
          ? '$sign$whole:$minutes'
          : '$sign$whole${glyphs.$1}$gap$minutes${glyphs.$2}';
    }
    final perSecond = switch (secondDecimals) {
      0 => 1,
      1 => 10,
      _ => 100,
    };
    final perMinute = 60 * perSecond;
    final whole = two(total ~/ (60 * perMinute));
    final minutes = two((total ~/ perMinute) % 60);
    final secondUnits = total % perMinute;
    final seconds = secondDecimals == 0
        ? two(secondUnits)
        : (secondUnits / perSecond)
              .toStringAsFixed(secondDecimals)
              .padLeft(3 + secondDecimals, '0');
    return shape == _Shape.colons
        ? '$sign$whole:$minutes:$seconds'
        : '$sign$whole${glyphs.$1}$gap$minutes${glyphs.$2}$gap$seconds'
              '${glyphs.$3}';
  }
}

enum _Shape { spaced, dense, colons }
