/// Default accent color hex, the red (#E86A6A), seeded into `app_settings` at
/// install. Existing installs keep their stored accent: migration v62 moved
/// the old blue seed (#6EB3EC) to the violet (#A48CF2) that was the default
/// then.
const kDefaultAccentColorHex = '#E86A6A';

/// Defines how the safety system behaves when weather/safety devices fail or are unavailable
enum SafetyFailMode {
  /// Treat unavailable safety data as safe; allow imaging to continue uninterrupted.
  failOpen,

  /// Treat unavailable safety data as unsafe; pause imaging and optionally park the mount.
  failClosed,

  /// Treat unavailable safety data as safe but emit a UI warning so the user is aware.
  warnOnly,
}

class ObserverLocation {
  const ObserverLocation({
    required this.latitude,
    required this.longitude,
    required this.elevation,
  });

  /// Every field is required: a partial location is refused.
  factory ObserverLocation.fromJson(Map<String, dynamic> json) =>
      ObserverLocation(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        elevation: (json['elevation'] as num).toDouble(),
      );

  final double latitude;
  final double longitude;
  final double elevation;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'latitude': latitude,
    'longitude': longitude,
    'elevation': elevation,
  };

  ObserverLocation copyWith({
    double? latitude,
    double? longitude,
    double? elevation,
  }) => ObserverLocation(
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    elevation: elevation ?? this.elevation,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other.runtimeType == runtimeType &&
          other is ObserverLocation &&
          other.latitude == latitude &&
          other.longitude == longitude &&
          other.elevation == elevation);

  @override
  int get hashCode => Object.hash(runtimeType, latitude, longitude, elevation);

  @override
  String toString() =>
      'ObserverLocation(latitude: $latitude, longitude: $longitude, '
      'elevation: $elevation)';
}
