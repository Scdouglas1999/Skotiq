// Guider status types.
import 'dart:convert';

/// One reference star the built-in multi-star guider tracks (up to 8), as
/// the guider status carries it.
class GuideStar {
  /// Stable 0-based index/identity within the tracked-star list.
  final int id;

  /// Centroid X in guide-camera pixels.
  final double x;

  /// Centroid Y in guide-camera pixels.
  final double y;

  /// Integrated flux (star mass / brightness indicator).
  final double flux;

  /// Signal-to-noise ratio.
  final double snr;

  /// Whether this is the active lock star (the centroid corrections key off).
  final bool isLock;

  /// Per-star residual magnitude in pixels on the most recent matched frame,
  /// or `null` before the star has been matched at least once.
  final double? residual;

  /// Relative weight this star carries in the sigma-clipped weighted centroid
  /// (flux/SNR derived). Higher = a brighter, cleaner star that pulls the
  /// aggregate guide offset harder. 0.0 when the native guider did not supply it.
  final double weight;

  const GuideStar({
    required this.id,
    required this.x,
    required this.y,
    this.flux = 0.0,
    this.snr = 0.0,
    this.isLock = false,
    this.residual,
    this.weight = 0.0,
  });

  /// Decode one star from the status JSON a host serves. Takes snake_case
  /// or camelCase keys.
  factory GuideStar.fromJson(Map<String, dynamic> json) {
    final isLock = json['is_lock'] ?? json['isLock'] ?? false;
    final residual = json['residual'];
    return GuideStar(
      id: (json['id'] as num?)?.toInt() ?? 0,
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      flux: (json['flux'] as num?)?.toDouble() ?? 0.0,
      snr: (json['snr'] as num?)?.toDouble() ?? 0.0,
      isLock: isLock is bool ? isLock : isLock == true,
      residual: residual == null ? null : (residual as num).toDouble(),
      weight: (json['weight'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'x': x,
    'y': y,
    'flux': flux,
    'snr': snr,
    'is_lock': isLock,
    'residual': residual,
    'weight': weight,
  };

  @override
  bool operator ==(Object other) =>
      other is GuideStar &&
      other.id == id &&
      other.x == x &&
      other.y == y &&
      other.flux == flux &&
      other.snr == snr &&
      other.isLock == isLock &&
      other.residual == residual &&
      other.weight == weight;

  @override
  int get hashCode =>
      Object.hash(id, x, y, flux, snr, isLock, residual, weight);
}

/// Decode the tracked-star list a host serves: a list of star maps, a map
/// with a `stars` list, or a JSON string of either; anything else is none.
List<GuideStar> decodeTrackedStars(Object? raw) {
  if (raw == null) return const [];
  Object? value = raw;
  if (value is String) {
    if (value.isEmpty) return const [];
    try {
      value = jsonDecode(value);
    } catch (_) {
      return const [];
    }
  }
  if (value is Map) {
    value = value['stars'];
  }
  if (value is List) {
    return value
        .whereType<Map>()
        .map((e) => GuideStar.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}

/// Plain words for a guider stop reason (see [Phd2Status.stopReason]), or
/// null for none. An unknown reason is shown as given rather than hidden.
String? guidingStopReasonText(String? reason) {
  return switch (reason) {
    null || '' => null,
    'autofocus' => 'Guiding paused for autofocus',
    'meridian_flip' => 'Guiding paused for the meridian flip',
    'tracking_limit_hold' =>
      'Guiding paused: the mount is at its tracking limit and waits for the flip',
    'mount_move' => 'Guiding paused while the mount moves',
    'pre_meridian_hold' =>
      'Guiding paused: the run waits at the meridian for the flip',
    'sequence_step' => "Guiding stopped by the sequence's Stop Guiding step",
    'dither_settle' => 'Guiding is settling after a dither',
    'run_stopped' => 'Guiding stopped because the run was stopped',
    'operator' => 'Guiding stopped from the guider controls',
    _ => 'Guiding stopped ($reason)',
  };
}

/// What the host's guider (PHD2 or the built-in multi-star guider) is doing.
class Phd2Status {
  /// The guider that answered: `phd2_guider` or the built-in guider's id.
  /// Null when no guider answered (no host, no native library).
  final String? deviceId;

  /// Current guider state (Stopped, Guiding, Calibrating, etc.)
  final String state;

  final bool connected;

  /// RMS error in RA (arcseconds)
  final double rmsRa;

  /// RMS error in Dec (arcseconds)
  final double rmsDec;

  /// Total RMS error (arcseconds)
  final double rmsTotal;

  /// Signal-to-noise ratio of guide star
  final double snr;

  /// Mass of the guide star (brightness indicator)
  final double starMass;

  /// Average guide star distance from lock position (pixels)
  final double avgDistance;

  /// Guide camera pixel scale in arcseconds per pixel, from PHD2's profile
  /// (or the built-in guider's camera and binning). Null when the guider has
  /// no scale to give, so guide errors stay in pixels.
  final double? pixelScale;

  /// Per-star tracked-star list. Populated by the built-in multi-star guider
  /// (up to 8 stars); empty for PHD2, which reports only the single
  /// aggregate lock star above.
  final List<GuideStar> trackedStars;

  /// Why the guider is stopped or held, as the native layer names it
  /// (`autofocus`, `meridian_flip`, `tracking_limit_hold`, `mount_move`,
  /// `pre_meridian_hold`, `sequence_step`, `dither_settle`, `run_stopped`,
  /// `operator`). Null while guiding runs or when nothing recorded a reason.
  /// A planned stop is not lost guiding; see [guidingStopReasonText].
  final String? stopReason;

  const Phd2Status({
    this.deviceId,
    required this.state,
    required this.connected,
    this.rmsRa = 0.0,
    this.rmsDec = 0.0,
    this.rmsTotal = 0.0,
    this.snr = 0.0,
    this.starMass = 0.0,
    this.avgDistance = 0.0,
    this.pixelScale,
    this.trackedStars = const [],
    this.stopReason,
  });

  factory Phd2Status.fromJson(Map<String, dynamic> json) {
    return Phd2Status(
      deviceId: json['deviceId'] as String?,
      state: json['state'] as String,
      connected: json['connected'] as bool,
      rmsRa: (json['rmsRa'] as num?)?.toDouble() ?? 0.0,
      rmsDec: (json['rmsDec'] as num?)?.toDouble() ?? 0.0,
      rmsTotal: (json['rmsTotal'] as num?)?.toDouble() ?? 0.0,
      snr: (json['snr'] as num?)?.toDouble() ?? 0.0,
      starMass: (json['starMass'] as num?)?.toDouble() ?? 0.0,
      avgDistance: (json['avgDistance'] as num?)?.toDouble() ?? 0.0,
      pixelScale: _positiveOrNull(json['pixelScale']),
      trackedStars: decodeTrackedStars(json['trackedStars']),
      stopReason: json['stopReason'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'state': state,
    'connected': connected,
    'rmsRa': rmsRa,
    'rmsDec': rmsDec,
    'rmsTotal': rmsTotal,
    'snr': snr,
    'starMass': starMass,
    'avgDistance': avgDistance,
    'pixelScale': pixelScale,
    'trackedStars': trackedStars.map((s) => s.toJson()).toList(),
    'stopReason': stopReason,
  };

  bool get isGuiding => state == 'Guiding';

  bool get isCalibrating => state == 'Calibrating';

  bool get isStopped => state == 'Stopped';

  static double? _positiveOrNull(Object? value) {
    if (value is! num) return null;
    final scale = value.toDouble();
    return scale.isFinite && scale > 0 ? scale : null;
  }
}
