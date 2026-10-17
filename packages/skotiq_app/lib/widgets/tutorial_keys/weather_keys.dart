import 'package:flutter/widgets.dart';

/// GlobalKeys for Weather tutorial targets
class WeatherTutorialKeys {
  static final radarMap = GlobalKey(debugLabel: 'weather_radar_map');
  static final timeline = GlobalKey(debugLabel: 'weather_timeline');
  static final statusCard = GlobalKey(debugLabel: 'weather_status_card');
  static final alertRadius = GlobalKey(debugLabel: 'weather_alert_radius');
  static final cloudMotion = GlobalKey(debugLabel: 'weather_cloud_motion');
  static final refreshBtn = GlobalKey(debugLabel: 'weather_refresh_btn');

  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;
    switch (keyId) {
      case 'weather_radar_map':
        return radarMap;
      case 'weather_timeline':
        return timeline;
      case 'weather_status_card':
        return statusCard;
      case 'weather_alert_radius':
        return alertRadius;
      case 'weather_cloud_motion':
        return cloudMotion;
      case 'weather_refresh_btn':
        return refreshBtn;
      default:
        return null;
    }
  }
}
