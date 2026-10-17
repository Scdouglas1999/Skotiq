import 'package:flutter/widgets.dart';

/// GlobalKeys for Planetarium tutorial targets
class PlanetariumTutorialKeys {
  static final skyView = GlobalKey(debugLabel: 'planetarium_sky_view');
  static final search = GlobalKey(debugLabel: 'planetarium_search');
  static final filterBtn = GlobalKey(debugLabel: 'planetarium_filter_btn');
  static final fovToggle = GlobalKey(debugLabel: 'planetarium_fov_toggle');
  static final slewBtn = GlobalKey(debugLabel: 'planetarium_slew_btn');
  static final objectPopup = GlobalKey(debugLabel: 'planetarium_object_popup');
  static final sendFraming = GlobalKey(debugLabel: 'planetarium_send_framing');
  static final addSequence = GlobalKey(debugLabel: 'planetarium_add_sequence');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'planetarium_sky_view':
        return skyView;
      case 'planetarium_search':
        return search;
      case 'planetarium_filter_btn':
        return filterBtn;
      case 'planetarium_fov_toggle':
        return fovToggle;
      case 'planetarium_slew_btn':
        return slewBtn;
      case 'planetarium_object_popup':
        return objectPopup;
      case 'planetarium_send_framing':
        return sendFraming;
      case 'planetarium_add_sequence':
        return addSequence;
      default:
        return null;
    }
  }
}
