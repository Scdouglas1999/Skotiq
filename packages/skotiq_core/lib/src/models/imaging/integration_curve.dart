/// Value types mirroring the `api_analyze_night` JSON result — the marginal-SNR
/// integration curve and the keep/cull subset recommendation produced by the
/// native optimizer (`AnalyzeNightResult` / `CurvePointDto` / `RecommendationDto`,
/// camelCase via serde `rename_all`).
///
/// These are pure, immutable value types with `fromJson`/`toJson` round-trips
/// and value equality, decoded defensively (nullable + defaults) so a partial
/// or forward-migrated payload never crashes the review screen.
library;

/// One point of the predicted integration curve: the best weight-ranked prefix
/// of `n` subs and its predicted integrated SNR, weighted-mean FWHM, and
/// cumulative integration time.
///
/// Mirrors the native `CurvePointDto`.
class IntegrationCurvePoint {
  /// Number of subs in this weight-ranked prefix (`1..=N`).
  final int n;

  /// Predicted integrated SNR of the best [n] subs.
  final double snr;

  /// Weighted-mean FWHM (px) over the prefix.
  final double fwhm;

  /// Cumulative integration time (seconds) of the prefix.
  final double cumulativeIntegrationS;

  const IntegrationCurvePoint({
    required this.n,
    required this.snr,
    required this.fwhm,
    required this.cumulativeIntegrationS,
  });

  /// Decode one curve point. Missing/typed-wrong keys fall back to zero rather
  /// than throwing.
  factory IntegrationCurvePoint.fromJson(Map<String, dynamic> json) {
    return IntegrationCurvePoint(
      n: _asInt(json['n']),
      snr: _asDouble(json['snr']),
      fwhm: _asDouble(json['fwhm']),
      cumulativeIntegrationS: _asDouble(json['cumulativeIntegrationS']),
    );
  }

  Map<String, dynamic> toJson() => {
    'n': n,
    'snr': snr,
    'fwhm': fwhm,
    'cumulativeIntegrationS': cumulativeIntegrationS,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IntegrationCurvePoint &&
          other.n == n &&
          other.snr == snr &&
          other.fwhm == fwhm &&
          other.cumulativeIntegrationS == cumulativeIntegrationS;

  @override
  int get hashCode => Object.hash(n, snr, fwhm, cumulativeIntegrationS);
}

/// The optimizer's keep/cull verdict. Mirrors the native `RecommendationDto`.
class SubsetRecommendation {
  /// How many weight-ranked subs to keep.
  final int keepN;

  /// Original indices (into the input arrays) of the kept subs, weight-ranked.
  final List<int> keptIndices;

  /// Predicted SNR change of the subset vs keeping all subs, in percent (never
  /// negative — the optimizer's never-harm floor guarantees it).
  final double predictedSnrGainPct;

  /// Human-readable summary.
  final String reason;

  const SubsetRecommendation({
    required this.keepN,
    required this.keptIndices,
    required this.predictedSnrGainPct,
    required this.reason,
  });

  factory SubsetRecommendation.fromJson(Map<String, dynamic> json) {
    return SubsetRecommendation(
      keepN: _asInt(json['keepN']),
      keptIndices: _asIntList(json['keptIndices']),
      predictedSnrGainPct: _asDouble(json['predictedSnrGainPct']),
      reason: json['reason'] is String ? json['reason'] as String : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'keepN': keepN,
    'keptIndices': keptIndices,
    'predictedSnrGainPct': predictedSnrGainPct,
    'reason': reason,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubsetRecommendation &&
          other.keepN == keepN &&
          _listEquals(other.keptIndices, keptIndices) &&
          other.predictedSnrGainPct == predictedSnrGainPct &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(
    keepN,
    Object.hashAll(keptIndices),
    predictedSnrGainPct,
    reason,
  );
}

/// The full `api_analyze_night` result: the predicted integration [points] over
/// the weight-ranked prefixes plus the keep/cull [recommendation].
///
/// Mirrors the native `AnalyzeNightResult`. The native payload names the point
/// array `curve`; this decoder accepts either `points` or `curve` so a renamed
/// or forward-migrated payload still round-trips.
class IntegrationCurve {
  /// The predicted integration curve over the weight-ranked prefixes.
  final List<IntegrationCurvePoint> points;

  /// The keep/cull recommendation.
  final SubsetRecommendation recommendation;

  const IntegrationCurve({required this.points, required this.recommendation});

  /// An empty curve with a no-op recommendation (keep nothing). Used as the
  /// fail-soft fallback when no analysis payload is available.
  static const IntegrationCurve empty = IntegrationCurve(
    points: [],
    recommendation: SubsetRecommendation(
      keepN: 0,
      keptIndices: [],
      predictedSnrGainPct: 0,
      reason: '',
    ),
  );

  factory IntegrationCurve.fromJson(Map<String, dynamic> json) {
    final raw = json['points'] ?? json['curve'];
    final points = <IntegrationCurvePoint>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          points.add(IntegrationCurvePoint.fromJson(item));
        }
      }
    }
    final rec = json['recommendation'];
    return IntegrationCurve(
      points: points,
      recommendation: rec is Map<String, dynamic>
          ? SubsetRecommendation.fromJson(rec)
          : empty.recommendation,
    );
  }

  Map<String, dynamic> toJson() => {
    'points': points.map((p) => p.toJson()).toList(),
    'recommendation': recommendation.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IntegrationCurve &&
          _listEquals(other.points, points) &&
          other.recommendation == recommendation;

  @override
  int get hashCode => Object.hash(Object.hashAll(points), recommendation);
}

double _asDouble(Object? v) => v is num ? v.toDouble() : 0.0;

int _asInt(Object? v) => v is num ? v.toInt() : 0;

List<int> _asIntList(Object? v) {
  if (v is List) {
    return [
      for (final e in v)
        if (e is num) e.toInt(),
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
