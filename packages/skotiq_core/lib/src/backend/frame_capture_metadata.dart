/// The equipment values a saved frame was taken with, as the session's
/// equipment snapshot records them. A sequence frame's come from its capture
/// record (the typed `FrameCaptureMetadata` on its frame event), a manual
/// frame's from the camera; a field nobody reported stays null rather than a
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
}
