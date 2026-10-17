import 'package:flutter/widgets.dart';

/// GlobalKeys for Analytics tutorial targets
class AnalyticsTutorialKeys {
  static final sessionTab = GlobalKey(debugLabel: 'analytics_session_tab');
  static final historyTab = GlobalKey(debugLabel: 'analytics_history_tab');
  static final equipmentTab = GlobalKey(debugLabel: 'analytics_equipment_tab');
  static final hfrChart = GlobalKey(debugLabel: 'analytics_hfr_chart');
  static final guidingChart = GlobalKey(debugLabel: 'analytics_guiding_chart');
  static final thumbnails = GlobalKey(debugLabel: 'analytics_thumbnails');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'analytics_session_tab':
        return sessionTab;
      case 'analytics_history_tab':
        return historyTab;
      case 'analytics_equipment_tab':
        return equipmentTab;
      case 'analytics_hfr_chart':
        return hfrChart;
      case 'analytics_guiding_chart':
        return guidingChart;
      case 'analytics_thumbnails':
        return thumbnails;
      default:
        return null;
    }
  }
}
