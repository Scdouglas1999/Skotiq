import 'package:flutter/widgets.dart';

/// GlobalKeys for Dashboard tutorial targets
class DashboardTutorialKeys {
  static final editButton = GlobalKey(debugLabel: 'dashboard_edit_button');
  static final livePreview = GlobalKey(debugLabel: 'dashboard_live_preview');
  static final captureControls =
      GlobalKey(debugLabel: 'dashboard_capture_controls');
  static final sessionWidget =
      GlobalKey(debugLabel: 'dashboard_session_widget');
  static final weatherWidget =
      GlobalKey(debugLabel: 'dashboard_weather_widget');
  static final guidingWidget =
      GlobalKey(debugLabel: 'dashboard_guiding_widget');
  static final mountWidget = GlobalKey(debugLabel: 'dashboard_mount_widget');
  static final focuserWidget =
      GlobalKey(debugLabel: 'dashboard_focuser_widget');
  static final equipmentStatus =
      GlobalKey(debugLabel: 'dashboard_equipment_status');
  static final sequenceWidget =
      GlobalKey(debugLabel: 'dashboard_sequence_widget');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'dashboard_edit_button':
        return editButton;
      case 'dashboard_live_preview':
        return livePreview;
      case 'dashboard_capture_controls':
        return captureControls;
      case 'dashboard_session_widget':
        return sessionWidget;
      case 'dashboard_weather_widget':
        return weatherWidget;
      case 'dashboard_guiding_widget':
        return guidingWidget;
      case 'dashboard_mount_widget':
        return mountWidget;
      case 'dashboard_focuser_widget':
        return focuserWidget;
      case 'dashboard_equipment_status':
        return equipmentStatus;
      case 'dashboard_sequence_widget':
        return sequenceWidget;
      default:
        return null;
    }
  }
}
