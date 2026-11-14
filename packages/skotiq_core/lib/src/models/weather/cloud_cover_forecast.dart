/// A model estimate for the site, independent of satellite imagery or sensors.
class CloudCoverForecast {
  const CloudCoverForecast({
    required this.percent,
    required this.source,
    required this.validAt,
  });

  final double percent;
  final String source;

  /// The model sample's valid time, not the time the app fetched it.
  final DateTime? validAt;

  /// Open-Meteo's `current` uses 15-minute model data. Requests explicitly use
  /// UTC; its ISO timestamp omits the suffix even in that time zone.
  static CloudCoverForecast? fromOpenMeteo(Map<String, dynamic> json) {
    final current = json['current'];
    if (current is! Map) return null;
    final percent = current['cloud_cover'];
    if (percent is! num || !percent.isFinite) return null;
    final time = current['time'];
    final parsed = time is String ? DateTime.tryParse(time) : null;
    return CloudCoverForecast(
      percent: percent.toDouble(),
      source: 'Open-Meteo',
      validAt: parsed == null
          ? null
          : parsed.isUtc
          ? parsed
          : DateTime.utc(
              parsed.year,
              parsed.month,
              parsed.day,
              parsed.hour,
              parsed.minute,
              parsed.second,
            ),
    );
  }
}
