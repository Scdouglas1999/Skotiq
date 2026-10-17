import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';

/// Sky reference frame a HiPS survey is tiled in.
///
/// Mirrors the `hips_frame` property defined by the IVOA HiPS 1.0 standard
/// (section 4.4.2). Only the equatorial and galactic frames are used by the
/// CDS image surveys the framing assistant consumes, but the standard also
/// defines ecliptic, so it is represented here for completeness rather than
/// silently coercing an unknown frame to equatorial.
enum HipsFrame {
  /// Equatorial (ICRS / J2000), `hips_frame=equatorial`.
  equatorial('equatorial'),

  /// Galactic, `hips_frame=galactic`.
  galactic('galactic'),

  /// Ecliptic, `hips_frame=ecliptic`.
  ecliptic('ecliptic');

  /// The literal value used in the `hips_frame` property line.
  final String wireValue;

  const HipsFrame(this.wireValue);

  /// Parses a `hips_frame` property value.
  ///
  /// Returns `null` for an unrecognised frame so the caller can surface a
  /// strict error rather than guessing — there is no silent coercion to
  /// equatorial.
  static HipsFrame? tryParse(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final frame in HipsFrame.values) {
      if (frame.wireValue == normalized) return frame;
    }
    return null;
  }
}

/// Image tile encoding(s) a HiPS survey publishes, parsed from `hips_tile_format`.
///
/// The HiPS standard allows a space-separated list (e.g. `jpeg png fits`); the
/// order is meaningful — it expresses the publisher's preferred format first.
enum HipsTileFormat {
  /// JPEG (`jpeg`), 8-bit lossy colour/greyscale preview tiles.
  jpeg('jpeg', 'jpg'),

  /// PNG (`png`), 8-bit lossless tiles supporting transparency at the
  /// survey's sky boundary.
  png('png', 'png'),

  /// FITS (`fits`), full-precision scientific tiles.
  fits('fits', 'fits');

  /// The token as it appears in a `hips_tile_format` property line.
  final String wireValue;

  /// The file extension used when building a tile path for this format.
  final String fileExtension;

  const HipsTileFormat(this.wireValue, this.fileExtension);

  /// Parses a single `hips_tile_format` token.
  ///
  /// Accepts the IVOA spelling `jpeg` and the common `jpg` alias. Returns
  /// `null` for an unrecognised token so the caller decides whether an unknown
  /// format is fatal or merely skipped.
  static HipsTileFormat? tryParse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'jpeg':
      case 'jpg':
        return HipsTileFormat.jpeg;
      case 'png':
        return HipsTileFormat.png;
      case 'fits':
        return HipsTileFormat.fits;
    }
    return null;
  }
}

/// Raised when a HiPS `properties` document cannot be parsed into a valid
/// [HipsProperties] value.
///
/// Malformed or missing-required HiPS metadata raises this rather than
/// defaulting: the survey's geometry and tile format cannot be guessed. The
/// [key] (when known) identifies the offending property line.
class HipsPropertiesParseException implements Exception {
  /// Human-readable description of the failure.
  final String message;

  /// The property key that triggered the failure, if a single key is at fault.
  final String? key;

  /// The raw value that failed to parse, if applicable.
  final String? rawValue;

  const HipsPropertiesParseException(this.message, {this.key, this.rawValue});

  @override
  String toString() {
    final buffer = StringBuffer('HipsPropertiesParseException: $message');
    if (key != null) buffer.write(' (key="$key"');
    if (key != null && rawValue != null) buffer.write(', value="$rawValue"');
    if (key != null) buffer.write(')');
    return buffer.toString();
  }
}

/// Parsed, validated contents of a HiPS `properties` metadata document.
///
/// A HiPS survey's `properties` file is a flat list of `key = value` lines
/// (UTF-8, `#` comments, `\`-continuation) defined by IVOA HiPS 1.0 section 4.4.
/// This value type captures the subset the framing tile layer needs to drive
/// level-of-detail selection, tile addressing and attribution, and validates it
/// strictly:
///
///  * [hipsOrder] (`hips_order`) is **required** — it is the maximum Norder the
///    survey publishes and is the upper bound for level-of-detail selection.
///  * [hipsOrderMin] (`hips_order_min`) defaults to `0` per the standard when
///    absent (the standard's documented default), not silently invented.
///  * [tileWidth] (`hips_tile_width`) falls back to the standard default of
///    `512` **and logs** when the key is missing — the only tolerated default
///    beyond documented standard defaults, surfaced rather than hidden.
///  * [tileFormats] (`hips_tile_format`) is **required** and must contain at
///    least one recognised format.
///  * [frame] (`hips_frame`) is **required**; an unknown frame is fatal.
///
/// Optional descriptive/attribution keys ([obsCopyright], [obsCopyrightUrl],
/// [creator]) and the suggested initial view ([initialRaDeg], [initialDecDeg],
/// [initialFovDeg]) are captured when present and left `null` otherwise.
///
/// Pure Dart: no Flutter or `dart:io` dependency, fully unit-testable.
class HipsProperties extends Equatable {
  /// The HiPS standard's documented default tile width when `hips_tile_width`
  /// is absent. Applying this default is logged, never silent.
  static const int defaultTileWidth = 512;

  /// The HiPS standard's documented default for `hips_order_min` when absent.
  static const int defaultOrderMin = 0;

  /// The conventional HiPS order the whole-sky `Allsky` map is published at.
  ///
  /// The HiPS standard (IVOA HiPS 1.0 §4.6) recommends publishing the Allsky map
  /// at `Norder3` (a single ~`Allsky.jpg` packing all `12*4^3 = 768` order-3
  /// tiles into one small image). It explicitly does NOT require an Allsky at the
  /// survey's `hips_order_min`: CDS DSS pyramids, for example, declare
  /// `hips_order_min = 0` yet 404 on `Norder0/Allsky.jpg` and only serve
  /// `Norder3/Allsky.jpg`. The loader therefore fetches the Allsky at
  /// [allskyOrder] (this constant clamped to the survey's published range), never
  /// blindly at `hips_order_min`. See [HipsProperties.allskyOrder].
  static const int standardAllskyOrder = 3;

  /// Maximum Norder (deepest level) the survey publishes (`hips_order`).
  final int hipsOrder;

  /// Minimum Norder the survey publishes (`hips_order_min`); `0` when absent.
  final int hipsOrderMin;

  /// Tile edge length in pixels (`hips_tile_width`); [defaultTileWidth] when
  /// absent (logged).
  final int tileWidth;

  /// Whether [tileWidth] came from [defaultTileWidth] because the key is
  /// absent. Exposed so callers/tests can assert the fallback path ran.
  final bool tileWidthWasDefaulted;

  /// Recognised tile encodings in publisher-preferred order
  /// (`hips_tile_format`). Never empty.
  final List<HipsTileFormat> tileFormats;

  /// Sky reference frame the survey is tiled in (`hips_frame`).
  final HipsFrame frame;

  /// Free-text copyright/attribution (`obs_copyright`), if published.
  final String? obsCopyright;

  /// URL to the survey's copyright/attribution page (`obs_copyright_url`), if
  /// published.
  final String? obsCopyrightUrl;

  /// Survey creator/curator identifier (`hips_creator`), if published.
  final String? creator;

  /// Suggested initial right ascension in degrees (`hips_initial_ra`), if
  /// published.
  final double? initialRaDeg;

  /// Suggested initial declination in degrees (`hips_initial_dec`), if
  /// published.
  final double? initialDecDeg;

  /// Suggested initial field of view in degrees (`hips_initial_fov`), if
  /// published.
  final double? initialFovDeg;

  const HipsProperties({
    required this.hipsOrder,
    required this.hipsOrderMin,
    required this.tileWidth,
    required this.tileWidthWasDefaulted,
    required this.tileFormats,
    required this.frame,
    this.obsCopyright,
    this.obsCopyrightUrl,
    this.creator,
    this.initialRaDeg,
    this.initialDecDeg,
    this.initialFovDeg,
  });

  /// The HiPS order the whole-sky `Allsky` map should be fetched at for this
  /// survey.
  ///
  /// This is the standard Allsky order ([standardAllskyOrder], `3`) clamped into
  /// the survey's published range `[hipsOrderMin, hipsOrder]`. It is NOT
  /// [hipsOrderMin]: the HiPS standard publishes the Allsky at the conventional
  /// order 3, and many real surveys (CDS DSS) declare `hips_order_min = 0` yet
  /// 404 on `Norder0/Allsky.jpg`, serving only `Norder3/Allsky.jpg`. The loader,
  /// the painter ([allskyOrder]) and the widget all read THIS value so they
  /// address the Allsky at the same order it is actually published at — making
  /// the never-blank coarse base layer work for real surveys, not just mocks.
  ///
  /// The clamp keeps it valid for the rare survey whose deepest order is below 3
  /// (it cannot publish an Allsky deeper than `hipsOrder`) or whose
  /// `hips_order_min` exceeds 3 (the Allsky cannot be coarser than the survey's
  /// own minimum published order).
  int get allskyOrder => standardAllskyOrder.clamp(hipsOrderMin, hipsOrder);

  /// The publisher-preferred tile format (first entry of [tileFormats]).
  HipsTileFormat get preferredFormat => tileFormats.first;

  /// Whether the survey publishes JPEG tiles (the framing layer's default
  /// preview encoding).
  bool get hasJpeg => tileFormats.contains(HipsTileFormat.jpeg);

  /// Whether the survey publishes PNG tiles (preferred where transparent sky
  /// boundaries matter).
  bool get hasPng => tileFormats.contains(HipsTileFormat.png);

  /// Parses a HiPS `properties` document into validated [HipsProperties].
  ///
  /// [logName] tags the log line emitted when [tileWidth] is defaulted; it
  /// defaults to `HipsProperties` so callers need not supply one.
  ///
  /// Throws [HipsPropertiesParseException] when a required key is missing, a
  /// value is malformed, or a value is out of range. There are no silent
  /// fallbacks beyond the two documented standard defaults
  /// ([defaultTileWidth], [defaultOrderMin]).
  factory HipsProperties.parse(
    String document, {
    String logName = 'HipsProperties',
  }) {
    final entries = _parseKeyValues(document);

    final hipsOrder = _requireInt(entries, 'hips_order', min: 0, max: 29);

    final int orderMin;
    final rawOrderMin = entries['hips_order_min'];
    if (rawOrderMin == null) {
      orderMin = defaultOrderMin;
    } else {
      orderMin = _parseIntValue(
        'hips_order_min',
        rawOrderMin,
        min: 0,
        max: hipsOrder,
      );
    }

    int tileWidth;
    bool tileWidthWasDefaulted;
    final rawTileWidth = entries['hips_tile_width'];
    if (rawTileWidth == null) {
      tileWidth = defaultTileWidth;
      tileWidthWasDefaulted = true;
      developer.log(
        'hips_tile_width absent in properties; applying HiPS standard default '
        'of $defaultTileWidth px',
        name: logName,
        level: 800, // INFO
      );
    } else {
      tileWidth = _parseIntValue(
        'hips_tile_width',
        rawTileWidth,
        min: 1,
        max: 16384,
      );
      tileWidthWasDefaulted = false;
    }
    // A power-of-two tile edge is required by the standard for the HEALPix
    // pyramid to address sub-tiles; a non-power-of-two width is malformed.
    if (tileWidth & (tileWidth - 1) != 0) {
      throw HipsPropertiesParseException(
        'hips_tile_width must be a power of two',
        key: 'hips_tile_width',
        rawValue: rawTileWidth ?? '$tileWidth',
      );
    }

    final rawFormats = entries['hips_tile_format'];
    if (rawFormats == null || rawFormats.trim().isEmpty) {
      throw const HipsPropertiesParseException(
        'required key hips_tile_format is missing or empty',
        key: 'hips_tile_format',
      );
    }
    final formats = <HipsTileFormat>[];
    for (final token in rawFormats.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final parsed = HipsTileFormat.tryParse(token);
      // Unknown tokens (e.g. a future format) are skipped rather than fatal —
      // the survey may publish a format we do not consume — but at least one
      // recognised format must remain or addressing is impossible.
      if (parsed != null && !formats.contains(parsed)) {
        formats.add(parsed);
      }
    }
    if (formats.isEmpty) {
      throw HipsPropertiesParseException(
        'hips_tile_format lists no format this client can decode',
        key: 'hips_tile_format',
        rawValue: rawFormats,
      );
    }

    final rawFrame = entries['hips_frame'];
    if (rawFrame == null || rawFrame.trim().isEmpty) {
      throw const HipsPropertiesParseException(
        'required key hips_frame is missing or empty',
        key: 'hips_frame',
      );
    }
    final frame = HipsFrame.tryParse(rawFrame);
    if (frame == null) {
      throw HipsPropertiesParseException(
        'unrecognised hips_frame',
        key: 'hips_frame',
        rawValue: rawFrame,
      );
    }

    return HipsProperties(
      hipsOrder: hipsOrder,
      hipsOrderMin: orderMin,
      tileWidth: tileWidth,
      tileWidthWasDefaulted: tileWidthWasDefaulted,
      tileFormats: List.unmodifiable(formats),
      frame: frame,
      obsCopyright: _optionalString(entries, 'obs_copyright'),
      obsCopyrightUrl: _optionalString(entries, 'obs_copyright_url'),
      creator: _optionalString(entries, 'hips_creator'),
      initialRaDeg: _optionalDouble(
        entries,
        'hips_initial_ra',
        min: 0,
        max: 360,
      ),
      initialDecDeg: _optionalDouble(
        entries,
        'hips_initial_dec',
        min: -90,
        max: 90,
      ),
      initialFovDeg: _optionalDouble(
        entries,
        'hips_initial_fov',
        min: 0,
        max: 360,
      ),
    );
  }

  /// Tokenises a HiPS `properties` document into a key -> value map.
  ///
  /// Honours the standard's syntax: blank lines and `#` comment lines are
  /// ignored; `key = value` and `key=value` are both accepted; a trailing
  /// backslash continues the value onto the next line. A duplicate key is an
  /// error — silently keeping the last write would hide a malformed document.
  static Map<String, String> _parseKeyValues(String document) {
    final result = <String, String>{};
    final lines = document.split('\n');
    var i = 0;
    while (i < lines.length) {
      var line = lines[i].replaceAll('\r', '');
      i++;
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final eq = line.indexOf('=');
      if (eq <= 0) {
        throw HipsPropertiesParseException(
          'malformed properties line (no key=value)',
          rawValue: line.trim(),
        );
      }
      final key = line.substring(0, eq).trim();
      var value = line.substring(eq + 1).trim();
      // Line continuation: a value ending in an unescaped backslash continues.
      while (value.endsWith('\\') && i < lines.length) {
        value = value.substring(0, value.length - 1);
        final next = lines[i].replaceAll('\r', '');
        i++;
        value = '$value${next.trim()}';
      }
      if (key.isEmpty) {
        throw HipsPropertiesParseException(
          'malformed properties line (empty key)',
          rawValue: line.trim(),
        );
      }
      if (result.containsKey(key)) {
        throw HipsPropertiesParseException(
          'duplicate key in properties document',
          key: key,
          rawValue: value,
        );
      }
      result[key] = value;
    }
    return result;
  }

  static int _requireInt(
    Map<String, String> entries,
    String key, {
    required int min,
    required int max,
  }) {
    final raw = entries[key];
    if (raw == null || raw.trim().isEmpty) {
      throw HipsPropertiesParseException(
        'required key $key is missing or empty',
        key: key,
      );
    }
    return _parseIntValue(key, raw, min: min, max: max);
  }

  static int _parseIntValue(
    String key,
    String raw, {
    required int min,
    required int max,
  }) {
    final value = int.tryParse(raw.trim());
    if (value == null) {
      throw HipsPropertiesParseException(
        'value is not an integer',
        key: key,
        rawValue: raw,
      );
    }
    if (value < min || value > max) {
      throw HipsPropertiesParseException(
        'value $value is out of the allowed range [$min, $max]',
        key: key,
        rawValue: raw,
      );
    }
    return value;
  }

  static String? _optionalString(Map<String, String> entries, String key) {
    final raw = entries[key];
    if (raw == null) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static double? _optionalDouble(
    Map<String, String> entries,
    String key, {
    required double min,
    required double max,
  }) {
    final raw = entries[key];
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final value = double.tryParse(trimmed);
    if (value == null) {
      throw HipsPropertiesParseException(
        'value is not a number',
        key: key,
        rawValue: raw,
      );
    }
    if (value < min || value > max) {
      throw HipsPropertiesParseException(
        'value $value is out of the allowed range [$min, $max]',
        key: key,
        rawValue: raw,
      );
    }
    return value;
  }

  @override
  List<Object?> get props => [
    hipsOrder,
    hipsOrderMin,
    tileWidth,
    tileWidthWasDefaulted,
    tileFormats,
    frame,
    obsCopyright,
    obsCopyrightUrl,
    creator,
    initialRaDeg,
    initialDecDeg,
    initialFovDeg,
  ];

  @override
  String toString() =>
      'HipsProperties(order=$hipsOrder, orderMin=$hipsOrderMin, '
      'tileWidth=$tileWidth, formats=$tileFormats, frame=$frame)';
}
