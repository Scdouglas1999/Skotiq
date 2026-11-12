import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_screen.dart';

/// Provider tracking the currently visible screen.
///
/// The app shell sets it from the route table whenever the operator moves to
/// another screen. [SmartNotificationService] reads it to show a notification
/// only when the operator is not already looking at the screen it is about.
final currentScreenProvider = StateProvider<AppScreen>(
  (ref) => AppScreen.dashboard,
);
