/// Shared sexagesimal formatters for Right Ascension (hours) and Declination
/// (degrees).
///
/// One parameterized implementation for every screen, so the math lives in
/// exactly one place instead of a private `_formatRa` / `_formatDec` helper per
/// caller.
///
/// IMPORTANT: the byte-for-byte output of a given [SexagesimalStyle] is part of
/// this class's contract — each call site picks the style that reproduces its
/// string exactly. Do not "tidy up" a style's output without auditing every
/// consumer, or what users see changes silently.
///
/// UNITS: every `ra*` entry point is explicit about what it is handed.
/// [CoordinateFormat.ra] / [CoordinateFormat.raHm] take **decimal hours**;
/// [CoordinateFormat.raFromDegrees] / [CoordinateFormat.raHmFromDegrees] take
/// **decimal degrees** and normalize into [0, 360) first. A single `_formatRa`
/// name covering both units is the hours-vs-degrees confusion that produces
/// slews to the wrong place.
library;

/// How the seconds component of a sexagesimal value is rendered.
enum SecondsPrecision {
  /// Round to the nearest whole second (`.round()`), no decimals.
  integerRounded,

  /// Truncate toward zero to a whole second (`.floor()` of a non-negative
  /// value), no decimals.
  integerFloored,

  /// One fractional digit (`toStringAsFixed(1)`), never zero-padded.
  oneDecimal,

  /// Two fractional digits, zero-padded to a fixed `SS.ss` width.
  twoDecimal,

  /// One fractional digit, zero-padded to a fixed `SS.s` width.
  oneDecimalPadded,
}

/// How the minutes component is quantized when only two fields are rendered
/// (see [CoordinateFormat.raHm] / [CoordinateFormat.decDm]).
enum MinutesPrecision {
  /// Round to the nearest whole minute, carrying 60 into the next hour/degree.
  rounded,

  /// Truncate toward zero to a whole minute.
  floored,
}

/// The glyphs that separate the three components, and which components are
/// zero-padded to two digits.
enum SexagesimalStyle {
  /// `HHh MMm SSs` / `±DD° MM' SS"` — letter/symbol units, single spaces,
  /// two-digit zero padding on every component.
  paddedLetters,

  /// `HH:MM:SS` / `±DD:MM:SS` — colon separated, two-digit zero padding.
  paddedColons,

  /// `HHhMMmSSs` / `±DD°MM'SS"` — no spaces, two-digit zero padding.
  compactLetters,

  /// `Hh Mm Ss` / `±D° M' S"` — single spaces, no zero padding at all.
  plainLetters,

  /// `Hh MMm SSs` / `±D° MM' SS"` — single spaces, leading field unpadded and
  /// the trailing fields zero-padded.
  leadPlainLetters,

  /// `HhMMmSSs` / `±D°MM'SS"` — no spaces, leading field unpadded and the
  /// trailing fields zero-padded.
  compactLeadPlainLetters,
}

/// Astronomical coordinate formatting (presentation only — no parsing).
///
/// See [SexagesimalStyle] / [SecondsPrecision] for the exact output shapes.
class CoordinateFormat {
  const CoordinateFormat._();

  /// Format Right Ascension given in **decimal hours** as three fields.
  ///
  /// [style] selects the separators/padding; [seconds] selects the seconds
  /// precision. With [wrapHours] false (the default) an input >24h is
  /// formatted as-is and a negative input is rendered as a signed magnitude;
  /// with [wrapHours] true the value is folded into [0, 24) *after* rounding,
  /// so 23:59:59.6 becomes 00:00:00 rather than a 24th hour.
  static String ra(
    double raHours, {
    SexagesimalStyle style = SexagesimalStyle.paddedLetters,
    SecondsPrecision seconds = SecondsPrecision.oneDecimal,
    bool wrapHours = false,
  }) {
    final unitsPerSecond = _unitsPerSecond(seconds);
    // Fold BEFORE quantizing: `floor()` of a magnitude then reflected around a
    // day is not `floor()` of the folded value (-0.005h is 23h59m, not 0h0m).
    // Dart's `%` already returns a non-negative result for a positive divisor.
    final magnitude = wrapHours ? raHours % 24.0 : raHours.abs();
    var total = _quantize(magnitude, 3600 * unitsPerSecond, seconds);
    final sign = wrapHours || raHours >= 0 ? '' : '-';
    if (wrapHours) {
      // The rounding itself can push 23:59:59.6 up into a 24th hour.
      total %= 24 * 3600 * unitsPerSecond;
    }
    final shape = _shape(style);
    final (h, m, secStr) = _split(
      total,
      unitsPerSecond,
      seconds,
      shape.padRest,
    );
    return _joinHms(sign, h, m, secStr, shape, _raGlyphs);
  }

  /// Format Right Ascension given in **decimal degrees** as three fields.
  ///
  /// The value is normalized into [0, 360) before the conversion to hours.
  static String raFromDegrees(
    double raDegrees, {
    SexagesimalStyle style = SexagesimalStyle.paddedLetters,
    SecondsPrecision seconds = SecondsPrecision.oneDecimal,
  }) => ra(
    _normalizeDegrees(raDegrees) / 15.0,
    style: style,
    seconds: seconds,
    wrapHours: true,
  );

  /// Format Right Ascension given in **decimal hours** as hours and minutes
  /// only (`HHh MMm`), quantized at the minute per [minutes].
  static String raHm(
    double raHours, {
    SexagesimalStyle style = SexagesimalStyle.paddedLetters,
    MinutesPrecision minutes = MinutesPrecision.floored,
    bool wrapHours = false,
  }) {
    final magnitude = wrapHours ? raHours % 24.0 : raHours.abs();
    var total = _quantizeMinutes(magnitude, minutes);
    final sign = wrapHours || raHours >= 0 ? '' : '-';
    if (wrapHours) total %= 24 * 60;
    final shape = _shape(style);
    return _joinHm(sign, total ~/ 60, total % 60, shape, _raGlyphs);
  }

  /// Format Right Ascension given in **decimal degrees** as hours and minutes
  /// only. The value is normalized into [0, 360) first.
  static String raHmFromDegrees(
    double raDegrees, {
    SexagesimalStyle style = SexagesimalStyle.paddedLetters,
    MinutesPrecision minutes = MinutesPrecision.floored,
  }) => raHm(
    _normalizeDegrees(raDegrees) / 15.0,
    style: style,
    minutes: minutes,
    wrapHours: true,
  );

  /// Format Declination given in **decimal degrees** as three fields.
  ///
  /// Always prefixes an explicit `+`/`-` sign.
  static String dec(
    double decDegrees, {
    SexagesimalStyle style = SexagesimalStyle.paddedLetters,
    SecondsPrecision seconds = SecondsPrecision.oneDecimal,
  }) {
    final sign = decDegrees >= 0 ? '+' : '-';
    final unitsPerSecond = _unitsPerSecond(seconds);
    final total = _quantize(decDegrees.abs(), 3600 * unitsPerSecond, seconds);
    final shape = _shape(style);
    final (d, m, secStr) = _split(
      total,
      unitsPerSecond,
      seconds,
      shape.padRest,
    );
    return _joinHms(sign, d, m, secStr, shape, _decGlyphs);
  }

  /// Format Declination given in **decimal degrees** as degrees and arcminutes
  /// only (`±DD° MM'`), quantized at the arcminute per [minutes].
  static String decDm(
    double decDegrees, {
    SexagesimalStyle style = SexagesimalStyle.paddedLetters,
    MinutesPrecision minutes = MinutesPrecision.floored,
  }) {
    final sign = decDegrees >= 0 ? '+' : '-';
    final total = _quantizeMinutes(decDegrees.abs(), minutes);
    final shape = _shape(style);
    return _joinHm(sign, total ~/ 60, total % 60, shape, _decGlyphs);
  }

  /// Format Declination as signed decimal degrees (`+45.3°` / `-12.0°`).
  ///
  /// The `-` comes from [num.toStringAsFixed]; only the `+` is added here.
  static String decDecimal(double decDegrees, {int fractionDigits = 1}) {
    final sign = decDegrees >= 0 ? '+' : '';
    return '$sign${decDegrees.toStringAsFixed(fractionDigits)}°';
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Quantize the WHOLE angle at the rendered precision so the carry between
  /// fields is structural.
  ///
  /// Rounding the seconds field on its own renders values that do not exist:
  /// 5.6h decomposes field-by-field to minutes=35, seconds=59.999…, which
  /// `toStringAsFixed(1)` shows as "05h 35m 60.0s" — a time this package's own
  /// `CoordinateParser` refuses to read back. Quantizing first means seconds
  /// can never reach 60 and minutes can never reach 60, for every precision.
  static int _quantize(
    double magnitude,
    int unitsPerWhole,
    SecondsPrecision precision,
  ) {
    final exact = magnitude * unitsPerWhole;
    // Only [SecondsPrecision.integerFloored] truncates; every other precision
    // rounds to its nearest representable value.
    return precision == SecondsPrecision.integerFloored
        ? exact.floor()
        : exact.round();
  }

  static int _quantizeMinutes(double magnitude, MinutesPrecision precision) {
    final exact = magnitude * 60;
    return precision == MinutesPrecision.floored
        ? exact.floor()
        : exact.round();
  }

  /// Split a quantized non-negative angle into whole/minutes/seconds-string.
  static (int whole, int minutes, String seconds) _split(
    int total,
    int unitsPerSecond,
    SecondsPrecision precision,
    bool padSeconds,
  ) {
    final unitsPerMinute = 60 * unitsPerSecond;
    final secondsUnits = total % unitsPerMinute;
    final wholeMinutes = total ~/ unitsPerMinute;
    return (
      wholeMinutes ~/ 60,
      wholeMinutes % 60,
      _formatSeconds(secondsUnits, unitsPerSecond, precision, padSeconds),
    );
  }

  /// The quantum [precision] renders at, as sub-second units per second.
  static int _unitsPerSecond(SecondsPrecision precision) {
    switch (precision) {
      case SecondsPrecision.integerRounded:
      case SecondsPrecision.integerFloored:
        return 1;
      case SecondsPrecision.oneDecimal:
      case SecondsPrecision.oneDecimalPadded:
        return 10;
      case SecondsPrecision.twoDecimal:
        return 100;
    }
  }

  static String _formatSeconds(
    int units,
    int unitsPerSecond,
    SecondsPrecision precision,
    bool padSeconds,
  ) {
    switch (precision) {
      case SecondsPrecision.integerRounded:
      case SecondsPrecision.integerFloored:
        return padSeconds ? _pad2(units) : units.toString();
      case SecondsPrecision.oneDecimal:
        return (units / unitsPerSecond).toStringAsFixed(1);
      case SecondsPrecision.oneDecimalPadded:
        return (units / unitsPerSecond).toStringAsFixed(1).padLeft(4, '0');
      case SecondsPrecision.twoDecimal:
        return (units / unitsPerSecond).toStringAsFixed(2).padLeft(5, '0');
    }
  }

  static String _pad2(int value) => value.toString().padLeft(2, '0');

  /// Fold degrees into [0, 360). Dart's `%` already returns a non-negative
  /// result for a positive divisor.
  static double _normalizeDegrees(double degrees) => degrees % 360.0;

  static ({String separator, bool padLead, bool padRest, bool colons}) _shape(
    SexagesimalStyle style,
  ) {
    switch (style) {
      case SexagesimalStyle.paddedLetters:
        return (separator: ' ', padLead: true, padRest: true, colons: false);
      case SexagesimalStyle.paddedColons:
        return (separator: '', padLead: true, padRest: true, colons: true);
      case SexagesimalStyle.compactLetters:
        return (separator: '', padLead: true, padRest: true, colons: false);
      case SexagesimalStyle.plainLetters:
        return (separator: ' ', padLead: false, padRest: false, colons: false);
      case SexagesimalStyle.leadPlainLetters:
        return (separator: ' ', padLead: false, padRest: true, colons: false);
      case SexagesimalStyle.compactLeadPlainLetters:
        return (separator: '', padLead: false, padRest: true, colons: false);
    }
  }

  /// (whole-field, minute-field, second-field) unit glyphs.
  static const _raGlyphs = ('h', 'm', 's');
  static const _decGlyphs = ('°', "'", '"');

  static String _joinHms(
    String sign,
    int whole,
    int minutes,
    String seconds,
    ({String separator, bool padLead, bool padRest, bool colons}) shape,
    (String, String, String) glyphs,
  ) {
    final w = shape.padLead ? _pad2(whole) : whole.toString();
    final m = shape.padRest ? _pad2(minutes) : minutes.toString();
    if (shape.colons) return '$sign$w:$m:$seconds';
    final sep = shape.separator;
    return '$sign$w${glyphs.$1}$sep$m${glyphs.$2}$sep$seconds${glyphs.$3}';
  }

  static String _joinHm(
    String sign,
    int whole,
    int minutes,
    ({String separator, bool padLead, bool padRest, bool colons}) shape,
    (String, String, String) glyphs,
  ) {
    final w = shape.padLead ? _pad2(whole) : whole.toString();
    final m = shape.padRest ? _pad2(minutes) : minutes.toString();
    if (shape.colons) return '$sign$w:$m';
    return '$sign$w${glyphs.$1}${shape.separator}$m${glyphs.$2}';
  }
}
