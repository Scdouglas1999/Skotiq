/// One hour of a forecast source's cloud cover at the site.
class CloudCoverSample {
  const CloudCoverSample({
    required this.time,
    required this.fraction,
    required this.isForecast,
  });

  /// The sample's valid time, UTC.
  final DateTime time;

  /// Cloud cover as a fraction of the sky, 0..1 (the source's percentage
  /// clamped and divided by 100).
  final double fraction;

  /// Whether [time] was after the moment the source was read.
  final bool isForecast;
}

/// The hourly cloud cover a forecast source gave for the site, or why it gave
/// none.
class CloudCoverSeries {
  const CloudCoverSeries._({
    required this.samples,
    required this.fetchedAt,
    this.providerName,
    this.errorMessage,
  });

  factory CloudCoverSeries.success(
    List<CloudCoverSample> samples, {
    String? providerName,
  }) => CloudCoverSeries._(
    samples: samples,
    fetchedAt: DateTime.now(),
    providerName: providerName,
  );

  factory CloudCoverSeries.error(String message) => CloudCoverSeries._(
    samples: const [],
    fetchedAt: DateTime.now(),
    errorMessage: message,
  );

  final List<CloudCoverSample> samples;
  final DateTime fetchedAt;

  /// The source's display name, when it is known.
  final String? providerName;

  /// Why the source gave no forecast; null on success.
  final String? errorMessage;

  bool get isSuccess => errorMessage == null;

  CloudCoverSeries withProviderName(String name) => CloudCoverSeries._(
    samples: samples,
    fetchedAt: fetchedAt,
    providerName: name,
    errorMessage: errorMessage,
  );
}
