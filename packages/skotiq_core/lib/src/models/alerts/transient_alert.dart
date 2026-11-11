import 'package:freezed_annotation/freezed_annotation.dart';

part 'transient_alert.freezed.dart';
part 'transient_alert.g.dart';

enum TransientType {
  /// Classical or recurrent nova
  nova,

  /// Core-collapse or thermonuclear supernova
  supernova,

  /// Cataclysmic variable (dwarf nova, AM CVn, etc.)
  cataclysmic,

  /// Comet discovery or outburst
  comet,

  /// Asteroid discovery or close approach
  asteroid,

  /// Variable star outburst or unusual behavior
  variableStar,

  /// Gamma-ray burst optical afterglow
  gammaRayBurst,

  /// Other transient not fitting above categories
  other,
}

enum TransientSource {
  /// American Association of Variable Star Observers
  aavso,

  /// Transient Name Server (IAU)
  tns,

  /// Minor Planet Electronic Circulars
  mpec,

  /// Central Bureau for Astronomical Telegrams
  cbat,

  /// Manually entered by user
  manual,
}

/// The sources [TransientAlertService] actually queries.
///
/// The enum above is the vocabulary an alert can be TAGGED with (a manually
/// entered alert, an imported one); this is the much shorter list of feeds the
/// product fetches. Every surface that offers or reports sources reads this
/// list, so a source with no working fetch is never presented as monitored —
/// a dead source reads to the operator as a quiet sky.
const Set<TransientSource> kFetchableTransientSources = {TransientSource.tns};

enum TransientAlertState {
  /// New alert, not yet reviewed
  newAlert,

  acknowledged,

  queued,

  observed,

  dismissed,
}

/// Astronomical transient alert for time-sensitive observations
@freezed
abstract class TransientAlert with _$TransientAlert {
  const factory TransientAlert({
    required String id,

    /// Object name/designation (e.g., "SN 2024abc", "V404 Cyg")
    required String name,

    required TransientType type,

    /// Right ascension in hours (0-24)
    required double raHours,

    /// Declination in degrees (-90 to +90)
    required double decDegrees,

    /// Current magnitude (null if unknown)
    double? magnitude,

    /// Peak/discovery magnitude if known
    double? peakMagnitude,

    required DateTime discoveryTime,

    required DateTime lastUpdated,

    required TransientSource source,

    /// URL to source announcement/page
    String? sourceUrl,

    /// Priority level 1-10 (1=highest, 10=lowest)
    @Default(5) int priority,

    String? notes,

    /// Spectral classification if available (e.g., "Type Ia", "He-rich")
    String? classification,

    @Default(TransientAlertState.newAlert) TransientAlertState state,
  }) = _TransientAlert;

  factory TransientAlert.fromJson(Map<String, dynamic> json) =>
      _$TransientAlertFromJson(json);
}

@freezed
abstract class TransientAlertSettings with _$TransientAlertSettings {
  const factory TransientAlertSettings({
    /// Which alert sources to monitor.
    ///
    /// Defaults to the fetchable feed plus manual entry, so no feed is
    /// reported as monitored unless it is queried. TNS needs its bot
    /// credentials before it returns anything (see tnsApiKey and
    /// Settings > Science).
    @Default({TransientSource.tns, TransientSource.manual})
    Set<TransientSource> enabledSources,

    /// Only show alerts brighter than this magnitude
    @Default(15.0) double magnitudeThreshold,

    @Default({
      TransientType.nova,
      TransientType.supernova,
      TransientType.cataclysmic,
      TransientType.comet,
      TransientType.asteroid,
      TransientType.variableStar,
      TransientType.gammaRayBurst,
      TransientType.other,
    })
    Set<TransientType> typesToMonitor,

    @Default(true) bool notifyOnNew,

    @Default(false) bool autoQueueBright,

    /// Magnitude threshold for auto-queuing (brighter = lower number)
    @Default(10.0) double autoQueueMagnitude,

    /// TNS (Transient Name Server) API key.
    /// Required for TNS alerts. Obtain at https://www.wis-tns.org/
    /// Leave empty to disable TNS source.
    String? tnsApiKey,
  }) = _TransientAlertSettings;

  factory TransientAlertSettings.fromJson(Map<String, dynamic> json) =>
      _$TransientAlertSettingsFromJson(json);

  static TransientAlertSettings get defaultSettings =>
      const TransientAlertSettings();
}
