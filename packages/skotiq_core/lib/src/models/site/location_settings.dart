/// Location settings for observer position
class LocationSettings {
  final double latitude;
  final double longitude;
  final double elevation;

  const LocationSettings({
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.elevation = 0.0,
  });

  LocationSettings copyWith({
    double? latitude,
    double? longitude,
    double? elevation,
  }) {
    return LocationSettings(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      elevation: elevation ?? this.elevation,
    );
  }
}
