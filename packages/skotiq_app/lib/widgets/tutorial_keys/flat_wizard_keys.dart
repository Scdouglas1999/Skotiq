import 'package:flutter/widgets.dart';

/// GlobalKeys for Flat Wizard tutorial targets
class FlatWizardTutorialKeys {
  static final tabs = GlobalKey(debugLabel: 'flat_tabs');
  static final filterSelect = GlobalKey(debugLabel: 'flat_filter_select');
  static final targetAdu = GlobalKey(debugLabel: 'flat_target_adu');
  static final frameCount = GlobalKey(debugLabel: 'flat_frame_count');
  static final preview = GlobalKey(debugLabel: 'flat_preview');
  static final startBtn = GlobalKey(debugLabel: 'flat_start_btn');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'flat_tabs':
        return tabs;
      case 'flat_filter_select':
        return filterSelect;
      case 'flat_target_adu':
        return targetAdu;
      case 'flat_frame_count':
        return frameCount;
      case 'flat_preview':
        return preview;
      case 'flat_start_btn':
        return startBtn;
      default:
        return null;
    }
  }
}
