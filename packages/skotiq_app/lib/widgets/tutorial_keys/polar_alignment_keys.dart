import 'package:flutter/widgets.dart';

/// GlobalKeys for Polar Alignment tutorial targets
class PolarAlignmentTutorialKeys {
  static final hemisphere = GlobalKey(debugLabel: 'polar_hemisphere');
  static final exposure = GlobalKey(debugLabel: 'polar_exposure');
  static final stepSize = GlobalKey(debugLabel: 'polar_step_size');
  static final startBtn = GlobalKey(debugLabel: 'polar_start_btn');
  static final imageView = GlobalKey(debugLabel: 'polar_image_view');
  static final errorDisplay = GlobalKey(debugLabel: 'polar_error_display');
  static final adjustment = GlobalKey(debugLabel: 'polar_adjustment');
  static final progress = GlobalKey(debugLabel: 'polar_progress');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'polar_hemisphere':
        return hemisphere;
      case 'polar_exposure':
        return exposure;
      case 'polar_step_size':
        return stepSize;
      case 'polar_start_btn':
        return startBtn;
      case 'polar_image_view':
        return imageView;
      case 'polar_error_display':
        return errorDisplay;
      case 'polar_adjustment':
        return adjustment;
      case 'polar_progress':
        return progress;
      default:
        return null;
    }
  }
}
