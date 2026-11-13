/// The event-data key names for the per-frame capture truth that rides on
/// `FrameAccepted` / `FrameRejected`.
///
/// One place for the strings because two surfaces read them: the FFI backend
/// writes them out of the typed bridge payload, and a paired remote client
/// receives the same map after a JSON round-trip. A key spelled differently on
/// either side would silently drop the field — exactly the class of failure
/// this whole path is here to remove.
class FrameCaptureKeys {
  const FrameCaptureKeys._();

  static const gain = 'gain';
  static const gainIsIso = 'gain_is_iso';
  static const offset = 'offset';
  static const sensorTempC = 'sensor_temp_c';
  static const coolerPowerPercent = 'cooler_power_percent';
  static const mountRaHours = 'mount_ra_hours';
  static const mountDecDegrees = 'mount_dec_degrees';
  static const mountAltitudeDeg = 'mount_altitude_deg';
  static const mountAzimuthDeg = 'mount_azimuth_deg';
  static const pierSide = 'pier_side';
  static const focuserPosition = 'focuser_position';
  static const focuserTemperatureC = 'focuser_temperature_c';
  static const rotatorAngleDeg = 'rotator_angle_deg';
  static const exposureSecs = 'exposure_secs';
  static const binX = 'bin_x';
  static const binY = 'bin_y';
  static const frameType = 'frame_type';
  static const targetId = 'target_id';
}

/// Per-frame capture truth as it arrives on a sequencer frame event.
///
/// Every value here was read off the equipment ONCE, into the Rust
/// `FrameContext` that the FITS writer stamped this frame's header from. It
/// travels on the event so the `captured_images` row is written from the
/// header's own source instead of a second reconstruction of the same
/// exposure — the reconstruction that left sequenced rows with NULL gain,
/// offset, sensor temperature, pointing, focuser position and rotator angle
/// while the file on disk carried all of them.
///
/// Everything is nullable, including [exposureSecs]: a frame event from an
/// older host (a paired phone talking to a not-yet-updated appliance) carries
/// none of these keys, and a missing field must stay NULL rather than become a
/// zero that reads as a real measurement.
class FrameCapture {
  const FrameCapture({
    this.gain,
    this.gainIsIso = false,
    this.offset,
    this.sensorTempC,
    this.coolerPowerPercent,
    this.mountRaHours,
    this.mountDecDegrees,
    this.mountAltitudeDeg,
    this.mountAzimuthDeg,
    this.pierSide,
    this.focuserPosition,
    this.focuserTemperatureC,
    this.rotatorAngleDeg,
    this.exposureSecs,
    this.binX,
    this.binY,
    this.frameType,
    this.targetId,
  });

  final int? gain;

  /// [gain] is the ISO speed of a DSLR or mirrorless frame.
  final bool gainIsIso;
  final int? offset;
  final double? sensorTempC;
  final double? coolerPowerPercent;

  /// Mount right ascension in HOURS, matching `captured_images.mount_ra`.
  /// The numeric FITS `RA` card is degrees; do not copy this into a
  /// degrees-valued field without multiplying by 15.
  final double? mountRaHours;
  final double? mountDecDegrees;
  final double? mountAltitudeDeg;
  final double? mountAzimuthDeg;

  /// `'East'` / `'West'`, or null when no mount answered.
  final String? pierSide;
  final int? focuserPosition;
  final double? focuserTemperatureC;
  final double? rotatorAngleDeg;
  final double? exposureSecs;
  final int? binX;
  final int? binY;

  /// FITS `IMAGETYP` — 'Light' / 'Dark' / 'Flat' / 'Bias'. Cased as the
  /// sequencer node configured it; the images DB stores it lowercased.
  final String? frameType;

  /// Sequencer-side target identifier (the TargetHeader node id), NOT the
  /// `targets.id` primary key the row's `target_id` column holds.
  final String? targetId;

  /// Whether the event carried the host's capture record: a host that sends
  /// it always sends the exposure, an older host sends none of the keys. In a
  /// record, a null gain or offset is a camera without that control.
  bool get hasRecord => exposureSecs != null;

  /// Read the capture fields back out of a frame event's `data` map. Absent
  /// keys stay null.
  factory FrameCapture.fromEventData(Map<String, dynamic> data) {
    double? asDouble(String key) => (data[key] as num?)?.toDouble();
    int? asInt(String key) => (data[key] as num?)?.toInt();
    String? asString(String key) {
      final v = data[key];
      return (v is String && v.isNotEmpty) ? v : null;
    }

    return FrameCapture(
      gain: asInt(FrameCaptureKeys.gain),
      gainIsIso: data[FrameCaptureKeys.gainIsIso] == true,
      offset: asInt(FrameCaptureKeys.offset),
      sensorTempC: asDouble(FrameCaptureKeys.sensorTempC),
      coolerPowerPercent: asDouble(FrameCaptureKeys.coolerPowerPercent),
      mountRaHours: asDouble(FrameCaptureKeys.mountRaHours),
      mountDecDegrees: asDouble(FrameCaptureKeys.mountDecDegrees),
      mountAltitudeDeg: asDouble(FrameCaptureKeys.mountAltitudeDeg),
      mountAzimuthDeg: asDouble(FrameCaptureKeys.mountAzimuthDeg),
      pierSide: asString(FrameCaptureKeys.pierSide),
      focuserPosition: asInt(FrameCaptureKeys.focuserPosition),
      focuserTemperatureC: asDouble(FrameCaptureKeys.focuserTemperatureC),
      rotatorAngleDeg: asDouble(FrameCaptureKeys.rotatorAngleDeg),
      exposureSecs: asDouble(FrameCaptureKeys.exposureSecs),
      binX: asInt(FrameCaptureKeys.binX),
      binY: asInt(FrameCaptureKeys.binY),
      frameType: asString(FrameCaptureKeys.frameType),
      targetId: asString(FrameCaptureKeys.targetId),
    );
  }
}
