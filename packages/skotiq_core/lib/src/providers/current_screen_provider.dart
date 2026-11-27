import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_screen.dart';

/// Provider tracking the currently visible screen.
///
/// The app shell sets it from the route table whenever the operator moves to
/// another screen. The notification router's in-app banner reads it to keep a
/// notice quiet while the operator is looking at the screen it is about.
final currentScreenProvider = StateProvider<AppScreen>(
  (ref) => AppScreen.dashboard,
);
