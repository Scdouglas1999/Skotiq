import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Watching a provider only while the widget is on screen.
///
/// Panels kept alive on a hidden tab (an IndexedStack keeps a half-typed field)
/// still rebuild whenever what they watch changes, and every rebuild costs the
/// app a frame that nobody sees: a hidden mount panel alone did so on every
/// telemetry poll. Hidden tabs sit under `TickerMode(enabled: false)`; while
/// they do, this reads the provider once instead of subscribing, and the
/// switch back to the tab rebuilds the panel with the current value.
extension WatchWhileShown on WidgetRef {
  T watchWhileShown<T>(BuildContext context, ProviderListenable<T> provider) =>
      TickerMode.valuesOf(context).enabled ? watch(provider) : read(provider);
}
