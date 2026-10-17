/// FITS file header data for image saving.
///
/// This class contains all metadata needed to write a FITS file header.
/// It mirrors the Rust FitsWriteHeader struct but is a pure Dart type.
class FitsWriteHeader {
  final String? objectName;
  final double exposureTime;
  final String captureTimestamp;
  final String frameType;
  final String? filter;
  final int? gain;
  final int? offset;
  final double? ccdTemp;
  final double? ra;
  final double? dec;
  final double? altitude;
  final String? telescope;
  final String? instrument;
  final String? observer;
  final int? binX;
  final int? binY;
  final double? focalLength;
  final double? aperture;
  final double? pixelSizeX;
  final double? pixelSizeY;
  final double? siteLatitude;
  final double? siteLongitude;
  final double? siteElevation;

  const FitsWriteHeader({
    this.objectName,
    required this.exposureTime,
    required this.captureTimestamp,
    required this.frameType,
    this.filter,
    this.gain,
    this.offset,
    this.ccdTemp,
    this.ra,
    this.dec,
    this.altitude,
    this.telescope,
    this.instrument,
    this.observer,
    this.binX,
    this.binY,
    this.focalLength,
    this.aperture,
    this.pixelSizeX,
    this.pixelSizeY,
    this.siteLatitude,
    this.siteLongitude,
    this.siteElevation,
  });

  /// Create from JSON (for network transport)
  factory FitsWriteHeader.fromJson(Map<String, dynamic> json) {
    return FitsWriteHeader(
      objectName: json['objectName'] as String?,
      exposureTime: (json['exposureTime'] as num).toDouble(),
      captureTimestamp: json['captureTimestamp'] as String,
      frameType: json['frameType'] as String,
      filter: json['filter'] as String?,
      gain: json['gain'] as int?,
      offset: json['offset'] as int?,
      ccdTemp: (json['ccdTemp'] as num?)?.toDouble(),
      ra: (json['ra'] as num?)?.toDouble(),
      dec: (json['dec'] as num?)?.toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      telescope: json['telescope'] as String?,
      instrument: json['instrument'] as String?,
      observer: json['observer'] as String?,
      binX: json['binX'] as int?,
      binY: json['binY'] as int?,
      focalLength: (json['focalLength'] as num?)?.toDouble(),
      aperture: (json['aperture'] as num?)?.toDouble(),
      pixelSizeX: (json['pixelSizeX'] as num?)?.toDouble(),
      pixelSizeY: (json['pixelSizeY'] as num?)?.toDouble(),
      siteLatitude: (json['siteLatitude'] as num?)?.toDouble(),
      siteLongitude: (json['siteLongitude'] as num?)?.toDouble(),
      siteElevation: (json['siteElevation'] as num?)?.toDouble(),
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'objectName': objectName,
    'exposureTime': exposureTime,
    'captureTimestamp': captureTimestamp,
    'frameType': frameType,
    'filter': filter,
    'gain': gain,
    'offset': offset,
    'ccdTemp': ccdTemp,
    'ra': ra,
    'dec': dec,
    'altitude': altitude,
    'telescope': telescope,
    'instrument': instrument,
    'observer': observer,
    'binX': binX,
    'binY': binY,
    'focalLength': focalLength,
    'aperture': aperture,
    'pixelSizeX': pixelSizeX,
    'pixelSizeY': pixelSizeY,
    'siteLatitude': siteLatitude,
    'siteLongitude': siteLongitude,
    'siteElevation': siteElevation,
  };
}
