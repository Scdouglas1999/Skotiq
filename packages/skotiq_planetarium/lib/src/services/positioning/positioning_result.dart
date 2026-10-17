/// Which tier produced a position.
///
/// They are not interchangeable and the difference is the whole point: a
/// Wi-Fi fix puts the observatory in its own yard, an IP fix puts it wherever
/// the internet provider hands off traffic — routinely a town over.
enum PositioningSource {
  /// The operating system's own location service (Windows Location Services,
  /// GeoClue, CoreLocation) via the `geolocator` plugin.
  platformService,

  /// A scan of nearby access points resolved by a positioning service.
  wifiScan,

  /// A third-party service's estimate from this machine's public IP address.
  ipAddress,
}

/// Which tier an outcome line is about.
enum PositioningTier { platformService, wifiScan, ipAddress }

/// What one tier did, whether or not it answered.
///
/// Kept for every tier, including the ones that succeeded, so a failure
/// message can name the actual reason ("Wi-Fi is switched off on this
/// machine") instead of a generic "no location found".
class TierOutcome {
  const TierOutcome({
    required this.tier,
    required this.succeeded,
    required this.detail,
  });

  final PositioningTier tier;
  final bool succeeded;

  /// One operator-readable sentence.
  final String detail;
}

/// A resolved position with everything needed to describe it honestly.
class PositioningResult {
  const PositioningResult({
    required this.latitude,
    required this.longitude,
    required this.source,
    this.accuracyMetres,
    this.provider,
    this.accessPointsUsed = 0,
    this.locationName,
  });

  final double latitude;
  final double longitude;

  /// Provider-reported horizontal accuracy in metres — the radius the fix is
  /// claimed to be inside.
  ///
  /// Null only for an IP fix whose provider reported none; both positioning
  /// services always report one, and the platform services report metres.
  /// Never invented: a null here prints as "no accuracy reported", not as a
  /// guess.
  final double? accuracyMetres;

  final PositioningSource source;

  /// Who answered: a host (`beaconDB`, `ipinfo.io`) or the platform service's
  /// own name.
  final String? provider;

  /// How many access points the positioning service was given. Zero for every
  /// source but [PositioningSource.wifiScan].
  final int accessPointsUsed;

  /// City/region label, when the answering service supplied one. The
  /// positioning services return coordinates only.
  final String? locationName;

  /// The radius at or under which a fix is "in your yard, not a town over"
  /// and the search stops.
  ///
  /// 150 m is the boundary between the two classes of answer rather than a
  /// target: a Wi-Fi fix in a covered area lands at 20–100 m, while every
  /// coarse source — an IP estimate, a positioning service's own IP fallback,
  /// a platform service with nothing but the same IP to work from — reports
  /// kilometres. Nothing real lands between them.
  static const double preciseMetres = 150;

  /// True when this fix is precise enough to stop looking.
  bool get isPrecise {
    final metres = accuracyMetres;
    return metres != null && metres <= preciseMetres;
  }

  /// How this fix ranks against another: smaller radius wins, and a fix with
  /// no reported accuracy ranks below every fix that has one.
  double get accuracyRank => accuracyMetres ?? double.infinity;

  /// One line naming the source and the radius, for the confirmation the
  /// operator reads after the fix is written.
  String get explanation => switch (source) {
    PositioningSource.wifiScan =>
      'Located to within ${formatDistance(accuracyMetres)} using '
          '$accessPointsUsed nearby Wi-Fi '
          '${accessPointsUsed == 1 ? 'network' : 'networks'}'
          '${provider == null ? '' : ' ($provider)'}.',
    PositioningSource.platformService =>
      accuracyMetres == null
          ? 'Located by ${provider ?? 'this machine’s location service'}, '
                'which reported no accuracy.'
          : 'Located to within ${formatDistance(accuracyMetres)} by '
                '${provider ?? 'this machine’s location service'}.',
    PositioningSource.ipAddress =>
      accuracyMetres == null
          ? 'Approximate only: from your internet address '
                '(${provider ?? 'a geolocation service'}). City level — '
                'typically tens of kilometres.'
          : 'Approximate only: from your internet address '
                '(${provider ?? 'a geolocation service'}), about '
                '${formatDistance(accuracyMetres)}.',
  };

  /// Metres under a kilometre, kilometres above it — nobody reads "25000 m".
  /// One decimal between 1 and 10 km so a 1.4 km radius does not round to the
  /// same "1 km" as a 900 m one.
  static String formatDistance(double? metres) {
    if (metres == null) return 'an unknown distance';
    if (metres < 1000) return '${metres.round()} m';
    final km = metres / 1000;
    return km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
  }
}

/// Everything one `locate()` call learned: the best fix, if any, and what
/// each tier did.
class PositioningAttempt {
  const PositioningAttempt({
    required this.fix,
    required this.outcomes,
    this.wifiRadioOff = false,
    this.wifiRadioCanBeEnabled = false,
  });

  /// The best fix any tier produced — smallest accuracy radius wins — or null
  /// when every allowed tier failed.
  final PositioningResult? fix;

  final List<TierOutcome> outcomes;

  /// The Wi-Fi tier was skipped because the radio is switched off. The one
  /// failure the operator can fix from here, so the UI offers it.
  final bool wifiRadioOff;

  /// Skotiq can switch that radio on itself on this platform.
  final bool wifiRadioCanBeEnabled;

  /// True when the precise tier is one click away: the radio is off and this
  /// platform lets the app switch it on.
  bool get canRetryWithWifi => wifiRadioOff && wifiRadioCanBeEnabled;

  /// Every tier's detail line, joined — the body of a "no fix" message, so it
  /// names causes instead of shrugging.
  String get failureDetail => outcomes.map((o) => o.detail).join(' ');
}
