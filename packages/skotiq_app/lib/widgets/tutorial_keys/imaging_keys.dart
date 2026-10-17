import 'package:flutter/widgets.dart';

/// GlobalKeys for Imaging tutorial targets
class ImagingTutorialKeys {
  static final tabBar = GlobalKey(debugLabel: 'imaging_tab_bar');
  static final previewArea = GlobalKey(debugLabel: 'imaging_preview_area');
  static final zoomControls = GlobalKey(debugLabel: 'imaging_zoom_controls');
  static final exposureSlider =
      GlobalKey(debugLabel: 'imaging_exposure_slider');
  static final gainControl = GlobalKey(debugLabel: 'imaging_gain_control');
  static final filterSelector =
      GlobalKey(debugLabel: 'imaging_filter_selector');
  static final snapshotBtn = GlobalKey(debugLabel: 'imaging_snapshot_btn');
  static final loopBtn = GlobalKey(debugLabel: 'imaging_loop_btn');
  static final abortBtn = GlobalKey(debugLabel: 'imaging_abort_btn');
  static final statsPanel = GlobalKey(debugLabel: 'imaging_stats_panel');
  static final mountTab = GlobalKey(debugLabel: 'imaging_mount_tab');
  static final focusTab = GlobalKey(debugLabel: 'imaging_focus_tab');
  static final histogram = GlobalKey(debugLabel: 'imaging_histogram');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'imaging_tab_bar':
        return tabBar;
      case 'imaging_preview_area':
        return previewArea;
      case 'imaging_zoom_controls':
        return zoomControls;
      case 'imaging_exposure_slider':
        return exposureSlider;
      case 'imaging_gain_control':
        return gainControl;
      case 'imaging_filter_selector':
        return filterSelector;
      case 'imaging_snapshot_btn':
        return snapshotBtn;
      case 'imaging_loop_btn':
        return loopBtn;
      case 'imaging_abort_btn':
        return abortBtn;
      case 'imaging_stats_panel':
        return statsPanel;
      case 'imaging_mount_tab':
        return mountTab;
      case 'imaging_focus_tab':
        return focusTab;
      case 'imaging_histogram':
        return histogram;
      default:
        return null;
    }
  }
}
