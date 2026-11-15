import '../../localization/skotiq_localizations.dart';
import '../../router/app_routes.dart';

export '../../router/app_routes.dart' show AppRoute, ShellNavGroup;

/// The shell's views of the route table: the rail, the phone bar and the
/// More sheet.
abstract final class ShellNavigation {
  ShellNavigation._();

  /// The rail, in rail order: Tonight, then Prepare / Observe / Review.
  ///
  /// Settings is deliberately not here: it lives in the top bar, because it is
  /// a place you go to change the app rather than a place you observe from.
  static final List<AppRoute> rail = [
    for (final route in AppRoute.values)
      if (route.group != null) route,
  ];

  /// The four routed phone bottom-bar slots; the fifth is "More", which the
  /// bar renders itself.
  static const List<AppRoute> phoneBar = [
    AppRoute.tonight,
    AppRoute.imaging,
    AppRoute.sequencer,
    AppRoute.guiding,
  ];

  /// Everything the More sheet lists: every rail destination without a phone
  /// slot, in rail order, then Settings, which has no rail slot.
  static final List<AppRoute> moreSheet = [
    for (final route in rail)
      if (!phoneBar.contains(route)) route,
    AppRoute.settings,
  ];

  /// Whether [destination] is where the operator is at [location]: the
  /// route there, a route nested below it, or a route it hosts on the rail
  /// (the Flat wizard is a Darkroom tool).
  static bool hosts(AppRoute destination, String location) =>
      destination.contains(location) ||
      AppRoute.of(location)?.railHost == destination;

  /// Index into [rail] of the destination that hosts [location], or -1 when
  /// none does.
  static int railIndexFor(String location) {
    final host = AppRoute.of(location)?.railHost;
    return host == null ? -1 : rail.indexOf(host);
  }
}

extension ShellNavGroupLabel on ShellNavGroup {
  /// The heading above the group, or null for [ShellNavGroup.home], which
  /// has none.
  String? label(SkotiqLocalizations l10n) => switch (this) {
        ShellNavGroup.home => null,
        ShellNavGroup.observe => l10n.text('navGroupObserve'),
        ShellNavGroup.prepare => l10n.text('navGroupPrepare'),
        ShellNavGroup.review => l10n.text('navGroupReview'),
      };
}
