import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/calibration_master_builder.dart';

final calibrationMasterBuildProvider = Provider<CalibrationMasterBuild>(
  (ref) => buildCalibrationMasterNative,
);
