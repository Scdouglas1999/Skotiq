import '../../database/daos/settings_dao.dart';
import '../calibration/fits_header_reader.dart';
import '../sensor_specs/camera_sensor_database.dart';
import 'science_camera_auto_config.dart';

/// Camera noise belongs to the exposure, not the camera's current setting.
/// Header-only reads also work when reprocessing with the rig disconnected.
Future<({double? gain, double? readNoise})> frameCameraNoise(
  SettingsDao settings,
  String imagePath, {
  int? capturedGain,
}) async {
  final configured = await settings.getAllSettings();
  double? positive(String key) {
    final value = double.tryParse(configured[key] ?? '');
    return value != null && value.isFinite && value > 0 ? value : null;
  }

  if (configured[ScienceCameraAutoConfig.autoManagedKey] == 'false') {
    return (
      gain: positive(ScienceCameraAutoConfig.gainKey),
      readNoise: positive(ScienceCameraAutoConfig.readNoiseKey),
    );
  }

  Map<String, String> header;
  try {
    header = await const FitsHeaderReader().readPrimaryHeader(imagePath);
  } on Exception {
    return (gain: null, readNoise: null);
  }
  final camera = FitsHeaderReader.stringValue(header, 'INSTRUME');
  final gain = capturedGain ?? FitsHeaderReader.intValue(header, 'GAIN');
  if (camera == null || gain == null) return (gain: null, readNoise: null);
  final entry = CameraSensorDatabase.curated.lookup(camera);
  // The curated charts describe raw ADC counts. FITS BITPIX=16 denotes the
  // driver's 16-bit container; MAXADU, when provided, identifies unscaled ADCs.
  final maxAdu = FitsHeaderReader.intValue(header, 'MAXADU') ?? 65535;
  final values = resolveScienceCameraValues(
    cameraName: camera,
    driverGain: gain,
    maxAdu: maxAdu,
    adcBitDepth: entry?.gainCurve?.adcBitDepth ?? 16,
    entry: entry,
    measurement: ScienceGainMeasurement.tryParse(
      configured[ScienceCameraAutoConfig.gainMeasurementKey],
    ),
  );
  return (gain: values.electronsPerAdu, readNoise: values.readNoiseE);
}
