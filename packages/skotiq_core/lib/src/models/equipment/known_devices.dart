import 'package:equatable/equatable.dart';

import '../backend/backend_types.dart';
import 'equipment_models.dart' show DeviceConnectionState;
import 'unified_device.dart';

/// One device the imaging host knows about: connected or connecting, named by
/// the active profile, or found by the last scan.
class KnownDevice extends Equatable {
  const KnownDevice({
    required this.device,
    required this.state,
    this.error,
    required this.inProfile,
    required this.foundByScan,
  });

  /// The device and every protocol it answers on. Its active backend is the
  /// one it is connected under, or the one it would connect under.
  final UnifiedDevice device;

  final DeviceConnectionState state;

  /// Why the last connect failed, when [state] is
  /// [DeviceConnectionState.error].
  final String? error;

  /// The active profile names this device.
  final bool inProfile;

  /// The last scan found this device.
  final bool foundByScan;

  DeviceType get type => device.type;

  String get id => device.activeDeviceId;

  String get name => device.displayName;

  bool get isConnected => state == DeviceConnectionState.connected;

  /// Wire row of `GET /api/devices`.
  Map<String, Object?> toJson() {
    final info = device.activeDevice;
    return {
      'id': info.id,
      'name': device.displayName,
      'deviceType': info.deviceType.name,
      'driverType': info.driverType.name,
      'description': info.description,
      'state': state.name,
      'error': error,
      'inProfile': inProfile,
      'foundByScan': foundByScan,
    };
  }

  factory KnownDevice.fromJson(Map<String, dynamic> json) {
    final info = DeviceInfo.fromJson(json);
    final stateName = json['state'];
    final state = DeviceConnectionState.values
        .where((s) => s.name == stateName)
        .firstOrNull;
    if (state == null) {
      throw FormatException('Unknown device state "$stateName"', json);
    }
    return KnownDevice(
      device: UnifiedDevice(
        canonicalName: info.id,
        displayName: info.name,
        type: info.deviceType,
        availableBackends: {info.driverType: info},
      ),
      state: state,
      error: json['error'] as String?,
      inProfile: json['inProfile'] == true,
      foundByScan: json['foundByScan'] == true,
    );
  }

  @override
  List<Object?> get props => [device, state, error, inProfile, foundByScan];
}

/// Every device the imaging host knows about, and when its last scan ran.
///
/// This is the answer of `GET /api/devices`: a linked client and the web
/// dashboard list what the host lists.
class KnownDevices extends Equatable {
  const KnownDevices({this.devices = const [], this.lastScanAt});

  /// In device-type order, then by name.
  final List<KnownDevice> devices;

  /// When the last scan finished, or null when none has run since launch.
  final DateTime? lastScanAt;

  int get connected => devices.where((d) => d.isConnected).length;

  Map<String, Object?> toJson() => {
    'devices': [for (final device in devices) device.toJson()],
    'lastScanAt': lastScanAt?.toUtc().toIso8601String(),
  };

  factory KnownDevices.fromJson(Map<String, dynamic> json) {
    final rows = json['devices'];
    if (rows is! List) {
      throw const FormatException('Known devices answer carries no devices');
    }
    final lastScanAt = json['lastScanAt'];
    return KnownDevices(
      devices: [
        for (final row in rows)
          KnownDevice.fromJson((row as Map).cast<String, dynamic>()),
      ],
      lastScanAt: lastScanAt is String
          ? DateTime.parse(lastScanAt).toLocal()
          : null,
    );
  }

  @override
  List<Object?> get props => [devices, lastScanAt];
}
