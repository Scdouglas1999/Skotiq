import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notification/notification_categories.dart';
import '../models/weather/weather_alert.dart';
import 'notification_router_provider.dart';
import 'weather_safety_provider.dart';

/// The weather notices one weather-safety verdict after another raises: unsafe
/// weather and its end, and clouds on the way and their clearing, each told
/// once per episode.
///
/// Weather judged from a monitored verdict only: with weather safety off, or
/// before the first evaluation, nothing is told. Dawn makes the verdict unsafe
/// too; that is the end of the night, not weather.
class WeatherNoticeTracker {
  bool _unsafeTold = false;
  bool _cloudsTold = false;

  /// The notices [state] raises after the states seen before it.
  List<(NotificationCategory, Map<String, String>)> next(
    WeatherSafetyState state,
  ) {
    if (!state.monitoringEnabled || state.lastEvaluation == null)
      return const [];
    final notices = <(NotificationCategory, Map<String, String>)>[];
    final unsafe =
        state.status == WeatherSafetyStatus.unsafe &&
        state.decisionSource != WeatherDecisionSource.dawn;
    if (unsafe && !_unsafeTold) {
      _unsafeTold = true;
      notices.add((
        NotificationCategory.weatherUnsafe,
        {
          kWeatherReasonContextKey:
              (state.actions.reason ?? 'Weather is unsafe').replaceFirst(
                RegExp(r'[.\s]+$'),
                '',
              ),
        },
      ));
    } else if (state.isSafe && _unsafeTold) {
      _unsafeTold = false;
      notices.add((NotificationCategory.weatherSafeAgain, const {}));
    }
    final cloudsComing =
        state.currentAlertLevel == AlertLevel.warning ||
        state.currentAlertLevel == AlertLevel.critical;
    if (cloudsComing && !_cloudsTold) {
      _cloudsTold = true;
      notices.add((NotificationCategory.cloudArriving, const {}));
    } else if (state.currentAlertLevel == AlertLevel.clear && _cloudsTold) {
      _cloudsTold = false;
      notices.add((NotificationCategory.cloudOpening, const {}));
    }
    return notices;
  }
}

/// What the weather-unsafe notice says made the weather unsafe.
const String kWeatherReasonContextKey = 'weather.reason';

/// Tells the weather notices of this host's weather-safety verdict through
/// the notification router. Runs on a host; a linked client hears them by the
/// host's push.
final weatherNoticesProvider = Provider<void>((ref) {
  final tracker = WeatherNoticeTracker();
  ref.listen<WeatherSafetyState>(weatherSafetyProvider, (_, state) {
    final router = ref.read(notificationRouterProvider);
    for (final (category, context) in tracker.next(state)) {
      router.route(category, context, severity: category.defaultSeverity);
    }
  }, fireImmediately: true);
});
