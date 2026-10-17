import 'package:flutter/widgets.dart';

/// GlobalKeys for Settings tutorial targets
class SettingsTutorialKeys {
  static final categories = GlobalKey(debugLabel: 'settings_categories');
  static final connection = GlobalKey(debugLabel: 'settings_connection');
  static final location = GlobalKey(debugLabel: 'settings_location');
  static final appearance = GlobalKey(debugLabel: 'settings_appearance');
  static final filePaths = GlobalKey(debugLabel: 'settings_file_paths');
  static final plateSolving = GlobalKey(debugLabel: 'settings_plate_solving');
  static final notifications = GlobalKey(debugLabel: 'settings_notifications');
  static final help = GlobalKey(debugLabel: 'settings_help');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'settings_categories':
        return categories;
      case 'settings_connection':
        return connection;
      case 'settings_location':
        return location;
      case 'settings_appearance':
        return appearance;
      case 'settings_file_paths':
        return filePaths;
      case 'settings_plate_solving':
        return plateSolving;
      case 'settings_notifications':
        return notifications;
      case 'settings_help':
        return help;
      default:
        return null;
    }
  }
}
