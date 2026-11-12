/// Device types and connection state for Skotiq equipment management.
library;

enum DeviceType {
  camera('Camera'),
  mount('Mount'),
  focuser('Focuser'),
  filterWheel('Filter wheel'),
  guider('Guider'),
  dome('Dome'),
  rotator('Rotator'),
  weather('Weather station'),
  safetyMonitor('Safety monitor'),
  switch_('Switch'),
  coverCalibrator('Cover calibrator');

  const DeviceType(this.displayName);

  /// The device's role as shown to the user, e.g. "Filter wheel".
  final String displayName;

  /// The role inside a sentence, e.g. "filter wheel".
  String get noun => displayName.toLowerCase();
}

/// The Connect All sweep's name for the built-in guider's camera, which is a
/// profile field and not a device slot.
const String guideCameraLabel = 'guide camera';

enum DriverType { ascom, alpaca, indi, native, simulator }

enum ConnectionState { disconnected, connecting, connected, error }

/// Side of pier for German Equatorial mounts
enum PierSide { east, west, unknown }

enum CameraState { idle, waiting, exposing, reading, download, error }
