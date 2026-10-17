import 'package:flutter/widgets.dart';

/// GlobalKeys for Equipment tutorial targets
class EquipmentTutorialKeys {
  static final profileSelector =
      GlobalKey(debugLabel: 'equipment_profile_selector');
  static final createProfileBtn =
      GlobalKey(debugLabel: 'equipment_create_profile_btn');
  static final quickConnectBar =
      GlobalKey(debugLabel: 'equipment_quick_connect_bar');
  static final discoveryTab = GlobalKey(debugLabel: 'equipment_discovery_tab');
  static final connectedTab = GlobalKey(debugLabel: 'equipment_connected_tab');
  static final settingsTab = GlobalKey(debugLabel: 'equipment_settings_tab');
  static final cameraCard = GlobalKey(debugLabel: 'equipment_camera_card');
  static final mountCard = GlobalKey(debugLabel: 'equipment_mount_card');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'equipment_profile_selector':
        return profileSelector;
      case 'equipment_create_profile_btn':
        return createProfileBtn;
      case 'equipment_quick_connect_bar':
        return quickConnectBar;
      case 'equipment_discovery_tab':
        return discoveryTab;
      case 'equipment_connected_tab':
        return connectedTab;
      case 'equipment_settings_tab':
        return settingsTab;
      case 'equipment_camera_card':
        return cameraCard;
      case 'equipment_mount_card':
        return mountCard;
      default:
        return null;
    }
  }
}
