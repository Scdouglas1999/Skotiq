import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Closes a page pushed straight onto a navigator (a target's page over the
/// Plan list) when the app moves to another place.
///
/// Such a page belongs to the place it was opened over. The shell's routed
/// pages carry no key, so a move between places updates the routed page
/// beneath in place and keeps every page pushed over it: the rail showed the
/// new place while the old page stayed on screen. Dialogs, sheets and menus
/// are not pages and are left to their own code.
class PlaceBoundPages extends NavigatorObserver {
  PlaceBoundPages(this._placeNow);

  /// The router's location now; a page records it when it opens.
  final String Function() _placeNow;

  final Map<Route<dynamic>, String> _openedAt = {};

  static bool _bound(Route<dynamic> route) =>
      route is PageRoute && route.settings is! Page;

  /// Close the pages opened over a place whenever [router] leaves it.
  void follow(GoRouter router) => router.routeInformationProvider
      .addListener(() => placeChanged(_placeNow()));

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_bound(route)) _openedAt[route] = _placeNow();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _openedAt.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _openedAt.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final place = oldRoute == null ? null : _openedAt.remove(oldRoute);
    if (newRoute != null && _bound(newRoute)) {
      _openedAt[newRoute] = place ?? _placeNow();
    }
  }

  /// The app is at [place]: close every page opened over another one. A page
  /// that closed itself on the way (popped before it navigated) is skipped.
  void placeChanged(String place) {
    final left = [
      for (final MapEntry(key: route, value: openedAt) in _openedAt.entries)
        if (openedAt != place) route,
    ];
    if (left.isEmpty) return;
    // Not from inside the router's notification: the navigator is rebuilt
    // for the new place first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in left) {
        if (route.isActive) route.navigator?.removeRoute(route);
      }
    });
  }
}
