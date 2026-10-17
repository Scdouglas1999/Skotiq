/// Value types mirroring the `api_detect_stars_photometry` JSON result — the
/// detected stars on a master and each one's per-channel background-subtracted
/// aperture flux (the input the Dart side cross-matches against a photometric
/// catalogue for SPCC colour calibration).
///
/// Pure, immutable value types with `fromJson`/`toJson` round-trips and value
/// equality, mirroring the native `DetectStarsPhotometryResult` /
/// `StarPhotometryDto` (camelCase via serde `rename_all`). Decoded defensively
/// (nullable + defaults) so a partial payload never throws.
library;

/// One detected star with its centroid, shape metrics, and per-channel aperture
/// flux. Mirrors the native `StarPhotometryDto`.
class DetectedStarPhotometry {
  /// Sub-pixel centroid X (px).
  final double x;

  /// Sub-pixel centroid Y (px).
  final double y;

  /// Detection flux on the mono plane (ADU).
  final double flux;

  /// Detection SNR.
  final double snr;

  /// Half-flux radius (px).
  final double hfr;

  /// FWHM (px).
  final double fwhm;

  /// Eccentricity (0 = round, →1 = trailed).
  final double eccentricity;

  /// Peak ADU of the detection on the rescaled (0..65535) mono detection plane.
  /// A detection whose peak sits at/near that ceiling is saturated — its
  /// per-channel [channelFlux] ratios clip at different ADU levels and give a
  /// wrong colour, so the cross-matcher rejects it. Defaults to `0.0` when a
  /// payload predates the field (then the saturation gate simply does not fire).
  final double peak;

  /// Background-subtracted aperture flux per image channel, in channel order.
  final List<double> channelFlux;

  const DetectedStarPhotometry({
    required this.x,
    required this.y,
    required this.flux,
    required this.snr,
    required this.hfr,
    required this.fwhm,
    required this.eccentricity,
    required this.channelFlux,
    this.peak = 0.0,
  });

  factory DetectedStarPhotometry.fromJson(Map<String, dynamic> json) {
    return DetectedStarPhotometry(
      x: _asDouble(json['x']),
      y: _asDouble(json['y']),
      flux: _asDouble(json['flux']),
      snr: _asDouble(json['snr']),
      hfr: _asDouble(json['hfr']),
      fwhm: _asDouble(json['fwhm']),
      eccentricity: _asDouble(json['eccentricity']),
      peak: _asDouble(json['peak']),
      channelFlux: _asDoubleList(json['channelFlux']),
    );
  }

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'flux': flux,
    'snr': snr,
    'hfr': hfr,
    'fwhm': fwhm,
    'eccentricity': eccentricity,
    'peak': peak,
    'channelFlux': channelFlux,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DetectedStarPhotometry &&
          other.x == x &&
          other.y == y &&
          other.flux == flux &&
          other.snr == snr &&
          other.hfr == hfr &&
          other.fwhm == fwhm &&
          other.eccentricity == eccentricity &&
          other.peak == peak &&
          _listEquals(other.channelFlux, channelFlux);

  @override
  int get hashCode => Object.hash(
    x,
    y,
    flux,
    snr,
    hfr,
    fwhm,
    eccentricity,
    peak,
    Object.hashAll(channelFlux),
  );
}

/// The full `api_detect_stars_photometry` result: master dimensions plus the
/// detected [stars]. Mirrors the native `DetectStarsPhotometryResult`.
class StarPhotometryResult {
  final int width;
  final int height;

  /// Number of channels measured per star (the [DetectedStarPhotometry.channelFlux]
  /// length).
  final int channels;

  final List<DetectedStarPhotometry> stars;

  const StarPhotometryResult({
    required this.width,
    required this.height,
    required this.channels,
    required this.stars,
  });

  /// An empty result (no stars). Used as the fail-soft fallback.
  static const StarPhotometryResult empty = StarPhotometryResult(
    width: 0,
    height: 0,
    channels: 0,
    stars: [],
  );

  factory StarPhotometryResult.fromJson(Map<String, dynamic> json) {
    final rawStars = json['stars'];
    final stars = <DetectedStarPhotometry>[];
    if (rawStars is List) {
      for (final item in rawStars) {
        if (item is Map<String, dynamic>) {
          stars.add(DetectedStarPhotometry.fromJson(item));
        }
      }
    }
    return StarPhotometryResult(
      width: _asInt(json['width']),
      height: _asInt(json['height']),
      channels: _asInt(json['channels']),
      stars: stars,
    );
  }

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'channels': channels,
    'stars': stars.map((s) => s.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StarPhotometryResult &&
          other.width == width &&
          other.height == height &&
          other.channels == channels &&
          _listEquals(other.stars, stars);

  @override
  int get hashCode =>
      Object.hash(width, height, channels, Object.hashAll(stars));
}

double _asDouble(Object? v) => v is num ? v.toDouble() : 0.0;

int _asInt(Object? v) => v is num ? v.toInt() : 0;

List<double> _asDoubleList(Object? v) {
  if (v is List) {
    return [
      for (final e in v)
        if (e is num) e.toDouble(),
    ];
  }
  return const [];
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
