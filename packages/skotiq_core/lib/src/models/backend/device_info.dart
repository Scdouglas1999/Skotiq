import 'device_types.dart';

/// Information about a discovered device
class DeviceInfo {
  final String id;
  final String name;
  final DeviceType deviceType;
  final DriverType driverType;
  final String description;
  final String driverVersion;

  const DeviceInfo({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.driverType,
    required this.description,
    required this.driverVersion,
  });

  /// Create from JSON (for network transport)
  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    final deviceTypeName = json['deviceType'] as String?;
    final driverTypeName = json['driverType'] as String?;

    final deviceType = DeviceType.values.where((e) => e.name == deviceTypeName);
    if (deviceType.isEmpty) {
      throw FormatException(
        'Unknown deviceType "$deviceTypeName" in DeviceInfo JSON',
      );
    }

    final driverType = DriverType.values.where((e) => e.name == driverTypeName);
    if (driverType.isEmpty) {
      throw FormatException(
        'Unknown driverType "$driverTypeName" in DeviceInfo JSON',
      );
    }

    return DeviceInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      deviceType: deviceType.first,
      driverType: driverType.first,
      description: json['description'] as String? ?? '',
      driverVersion: json['driverVersion'] as String? ?? '',
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'deviceType': deviceType.name,
    'driverType': driverType.name,
    'description': description,
    'driverVersion': driverVersion,
  };

  @override
  String toString() => 'DeviceInfo($name, $deviceType, $driverType)';
}
