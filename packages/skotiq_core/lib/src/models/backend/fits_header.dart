/// What the caller of a manual capture knows about the frame it saves: what
/// it was told to take, who and where the observer is, and which devices make
/// up the rig.
///
/// Everything the devices know (pointing, pier side, focuser, rotator,
/// temperatures, guiding, pixel size, the exposure the camera recorded) is
/// read from them by the host when the frame is saved, the same way and at
/// the same moment as for a sequence's frame, so the two carry the same
/// header apart from the cards that tie a frame to a run.
class FitsWriteHeader {
  final String? objectName;

  /// Seconds the exposure was commanded for.
  final double exposureTime;

  /// When the exposure started, UTC ISO-8601, as the caller recorded it. The
  /// host's image view and the database row use it; `DATE-OBS` is the camera
  /// layer's own record of the same instant.
  final String captureTimestamp;
  final String frameType;

  /// The filter the capture was set to. Null records the one the wheel
  /// reports.
  final String? filter;

  /// Commanded gain and offset, for a camera that does not report its own.
  final int? gain;
  final int? offset;
  final int? binX;
  final int? binY;
  final String? telescope;

  /// The camera as the equipment profile names it. Null records the
  /// driver's model name.
  final String? instrument;
  final String? observer;
  final double? focalLength;
  final double? aperture;
  final double? siteLatitude;
  final double? siteLongitude;
  final double? siteElevation;

  /// The rig's devices. The host reads each one when it saves the frame; a
  /// null id, or a device that is not connected, leaves its cards out.
  final String? mountId;
  final String? focuserId;
  final String? filterWheelId;
  final String? rotatorId;

  const FitsWriteHeader({
    this.objectName,
    required this.exposureTime,
    required this.captureTimestamp,
    required this.frameType,
    this.filter,
    this.gain,
    this.offset,
    this.binX,
    this.binY,
    this.telescope,
    this.instrument,
    this.observer,
    this.focalLength,
    this.aperture,
    this.siteLatitude,
    this.siteLongitude,
    this.siteElevation,
    this.mountId,
    this.focuserId,
    this.filterWheelId,
    this.rotatorId,
  });

  factory FitsWriteHeader.fromJson(Map<String, dynamic> json) {
    return FitsWriteHeader(
      objectName: json['objectName'] as String?,
      exposureTime: (json['exposureTime'] as num).toDouble(),
      captureTimestamp: json['captureTimestamp'] as String,
      frameType: json['frameType'] as String,
      filter: json['filter'] as String?,
      gain: json['gain'] as int?,
      offset: json['offset'] as int?,
      binX: json['binX'] as int?,
      binY: json['binY'] as int?,
      telescope: json['telescope'] as String?,
      instrument: json['instrument'] as String?,
      observer: json['observer'] as String?,
      focalLength: (json['focalLength'] as num?)?.toDouble(),
      aperture: (json['aperture'] as num?)?.toDouble(),
      siteLatitude: (json['siteLatitude'] as num?)?.toDouble(),
      siteLongitude: (json['siteLongitude'] as num?)?.toDouble(),
      siteElevation: (json['siteElevation'] as num?)?.toDouble(),
      mountId: json['mountId'] as String?,
      focuserId: json['focuserId'] as String?,
      filterWheelId: json['filterWheelId'] as String?,
      rotatorId: json['rotatorId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'objectName': objectName,
    'exposureTime': exposureTime,
    'captureTimestamp': captureTimestamp,
    'frameType': frameType,
    'filter': filter,
    'gain': gain,
    'offset': offset,
    'binX': binX,
    'binY': binY,
    'telescope': telescope,
    'instrument': instrument,
    'observer': observer,
    'focalLength': focalLength,
    'aperture': aperture,
    'siteLatitude': siteLatitude,
    'siteLongitude': siteLongitude,
    'siteElevation': siteElevation,
    'mountId': mountId,
    'focuserId': focuserId,
    'filterWheelId': filterWheelId,
    'rotatorId': rotatorId,
  };
}
