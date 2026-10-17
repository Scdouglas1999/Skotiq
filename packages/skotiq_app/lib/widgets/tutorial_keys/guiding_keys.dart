import 'package:flutter/widgets.dart';

/// GlobalKeys for Guiding tutorial targets
class GuidingTutorialKeys {
  static final connectBtn = GlobalKey(debugLabel: 'guiding_connect_btn');
  static final statusBar = GlobalKey(debugLabel: 'guiding_status_bar');
  static final starView = GlobalKey(debugLabel: 'guiding_star_view');
  static final targetDisplay = GlobalKey(debugLabel: 'guiding_target_display');
  static final graph = GlobalKey(debugLabel: 'guiding_graph');
  static final rmsDisplay = GlobalKey(debugLabel: 'guiding_rms_display');
  static final controls = GlobalKey(debugLabel: 'guiding_controls');
  static final brainBtn = GlobalKey(debugLabel: 'guiding_brain_btn');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'guiding_connect_btn':
        return connectBtn;
      case 'guiding_status_bar':
        return statusBar;
      case 'guiding_star_view':
        return starView;
      case 'guiding_target_display':
        return targetDisplay;
      case 'guiding_graph':
        return graph;
      case 'guiding_rms_display':
        return rmsDisplay;
      case 'guiding_controls':
        return controls;
      case 'guiding_brain_btn':
        return brainBtn;
      default:
        return null;
    }
  }
}
