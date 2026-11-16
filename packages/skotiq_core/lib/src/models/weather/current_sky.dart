import 'cloud_cover_forecast.dart';

/// Total cloud amount as a METAR reports it, in eighths of the sky (oktas).
enum CloudAmount {
  clear(0),
  few(19),
  scattered(44),
  broken(75),
  overcast(100),

  /// Sky hidden by fog, smoke or precipitation (vertical visibility).
  obscured(100);

  const CloudAmount(this.percent);

  /// The middle of the okta band: FEW 1-2/8, SCT 3-4/8, BKN 5-7/8.
  final double percent;

  /// The METAR cover code (CLR, SKC, NCD, NSC, CAVOK, FEW, SCT, BKN, OVC,
  /// OVX, VV), or null for a code that says nothing about cloud.
  static CloudAmount? fromMetar(String code) => switch (code.toUpperCase()) {
    'CLR' || 'SKC' || 'NCD' || 'NSC' || 'CAVOK' => clear,
    'FEW' => few,
    'SCT' => scattered,
    'BKN' => broken,
    'OVC' => overcast,
    'OVX' || 'VV' => obscured,
    _ => null,
  };
}

/// The latest report from the weather station nearest the site.
class StationSky {
  const StationSky({
    required this.stationId,
    required this.stationName,
    required this.distanceKm,
    required this.observedAt,
    required this.amount,
    required this.seesUpToFeet,
  });

  /// A station farther than this says little about the sky over the site.
  static const maximumDistanceKm = 40.0;

  /// METARs are hourly; an older report is a past sky.
  static const maximumAge = Duration(minutes: 90);

  /// ICAO identifier, e.g. "KPHL".
  final String stationId;
  final String stationName;
  final double distanceKm;
  final DateTime observedAt;
  final CloudAmount amount;

  /// The height the report covers, or null when an observer reported the
  /// whole sky. An automated ceilometer reports cloud below 12,000 ft only;
  /// CAVOK says nothing above 5,000 ft.
  final int? seesUpToFeet;

  double get percent => amount.percent;
}

/// The sky over the site now: a station observation when one is near and
/// recent, the forecast model's value for this quarter hour otherwise.
///
/// [percent] is the one figure the screens and weather safety use.
class CurrentSky {
  const CurrentSky({this.station, this.model, this.modelHighCloudPercent})
    : assert(station != null || model != null);

  final StationSky? station;

  /// The model's cloud cover for now, kept beside an observation so the two
  /// can be compared.
  final CloudCoverForecast? model;

  /// The model's high cloud (above about 6 km): what an automated station
  /// cannot see.
  final double? modelHighCloudPercent;

  /// Two sources this far apart in percent are reported as disagreeing.
  static const disagreementPercent = 40.0;

  /// The station's cloud amount; for a report limited to low cloud, the
  /// model's high cloud when that is more.
  double get percent {
    final station = this.station;
    if (station == null) return model!.percent;
    final high = modelHighCloudPercent;
    if (station.seesUpToFeet != null &&
        high != null &&
        high > station.percent) {
      return high;
    }
    return station.percent;
  }

  /// When [percent] was true: the observation time, else the model's
  /// valid time.
  DateTime? get validAt => station?.observedAt ?? model?.validAt;

  bool get isObservation => station != null;

  /// The station and the model differ by [disagreementPercent] or more.
  bool get sourcesDisagree {
    final station = this.station;
    final model = this.model;
    return station != null &&
        model != null &&
        (station.percent - model.percent).abs() >= disagreementPercent;
  }

  /// A short attribution for lists and logs: "KOQN station" or the model's
  /// source.
  String get source =>
      station == null ? model!.source : '${station!.stationId} station';
}
