import 'package:flutter/widgets.dart';

/// GlobalKeys for Framing tutorial targets
class FramingTutorialKeys {
  static final targetSearch = GlobalKey(debugLabel: 'framing_target_search');
  static final canvas = GlobalKey(debugLabel: 'framing_canvas');
  static final fovRect = GlobalKey(debugLabel: 'framing_fov_rect');
  static final rotation = GlobalKey(debugLabel: 'framing_rotation');
  static final coordinates = GlobalKey(debugLabel: 'framing_coordinates');
  static final altitudeChart = GlobalKey(debugLabel: 'framing_altitude_chart');
  static final mosaicBtn = GlobalKey(debugLabel: 'framing_mosaic_btn');
  static final slewBtn = GlobalKey(debugLabel: 'framing_slew_btn');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'framing_target_search':
        return targetSearch;
      case 'framing_canvas':
        return canvas;
      case 'framing_fov_rect':
        return fovRect;
      case 'framing_rotation':
        return rotation;
      case 'framing_coordinates':
        return coordinates;
      case 'framing_altitude_chart':
        return altitudeChart;
      case 'framing_mosaic_btn':
        return mosaicBtn;
      case 'framing_slew_btn':
        return slewBtn;
      default:
        return null;
    }
  }
}
