import 'package:flutter/widgets.dart';

/// GlobalKeys for Sequencer tutorial targets
class SequencerTutorialKeys {
  static final tabBuilder = GlobalKey(debugLabel: 'sequencer_tab_builder');
  static final tabTemplates = GlobalKey(debugLabel: 'sequencer_tab_templates');
  static final nodePalette = GlobalKey(debugLabel: 'sequencer_node_palette');
  static final canvas = GlobalKey(debugLabel: 'sequencer_canvas');
  static final targetNode = GlobalKey(debugLabel: 'sequencer_target_node');
  static final captureNode = GlobalKey(debugLabel: 'sequencer_capture_node');
  static final propertiesPanel =
      GlobalKey(debugLabel: 'sequencer_properties_panel');
  static final toolbar = GlobalKey(debugLabel: 'sequencer_toolbar');
  static final progressBar = GlobalKey(debugLabel: 'sequencer_progress_bar');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'sequencer_tab_builder':
        return tabBuilder;
      case 'sequencer_tab_templates':
        return tabTemplates;
      case 'sequencer_node_palette':
        return nodePalette;
      case 'sequencer_canvas':
        return canvas;
      case 'sequencer_target_node':
        return targetNode;
      case 'sequencer_capture_node':
        return captureNode;
      case 'sequencer_properties_panel':
        return propertiesPanel;
      case 'sequencer_toolbar':
        return toolbar;
      case 'sequencer_progress_bar':
        return progressBar;
      default:
        return null;
    }
  }
}
