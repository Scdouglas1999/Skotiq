import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/end_of_night_calibration/eon_trigger.dart';

final endOfNightCalibrationCoordinatorProvider =
    Provider<EndOfNightCalibrationCoordinator>(
      EndOfNightCalibrationCoordinator.new,
    );
