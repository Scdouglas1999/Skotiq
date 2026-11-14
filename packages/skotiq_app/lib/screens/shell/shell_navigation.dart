import '../../localization/skotiq_localizations.dart';
import '../../router/app_routes.dart';

export '../../router/app_routes.dart' show AppRoute, ShellNavGroup;

/// The shell's views of the route table: the rail, the phone bar and the
/// More sheet.
abstract final class ShellNavigation {
  ShellNavigation._();

  /// The rail, in rail order, grouped Observe / Prepare / Review.
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
  /// slot, then Session replay and Settings, which have no rail slot.
  static final List<AppRoute> moreSheet = [
    for (final route in rail)
      if (!phoneBar.contains(route)) route,
    AppRoute.sessionReplay,
    AppRoute.settings,
  ];

  /// Index into [rail] of the destination that hosts [location], or -1 when
  /// none does.
  static int railIndexFor(String location) {
    final host = AppRoute.of(location)?.railHost;
    return host == null ? -1 : rail.indexOf(host);
  }
}

extension ShellNavGroupLabel on ShellNavGroup {
  String label(SkotiqLocalizations l10n) => switch (this) {
        ShellNavGroup.observe => l10n.text('navGroupObserve'),
        ShellNavGroup.prepare => l10n.text('navGroupPrepare'),
        ShellNavGroup.review => l10n.text('navGroupReview'),
      };
}
