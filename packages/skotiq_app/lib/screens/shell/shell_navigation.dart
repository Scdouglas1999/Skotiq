import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../localization/skotiq_localizations.dart';

/// The three things an operator does with this app, in the order a night runs.
///
/// The rail is grouped by them rather than being one flat list, because
/// a flat list makes "Weather" and "Guiding" look like peers of equal weight
/// when one is a thing you check before you start and the other is a thing you
/// watch while running.
enum ShellNavGroup { observe, prepare, review }

/// One primary shell destination (rail + indexed tab selection).
class ShellPrimaryDestination {
  final String route;
  final IconData icon;
  final String Function(SkotiqLocalizations l10n) label;

  /// Which rail group this destination sits under.
  final ShellNavGroup group;

  const ShellPrimaryDestination({
    required this.route,
    required this.icon,
    required this.label,
    required this.group,
  });
}

/// Route-only destination for the phone bottom nav (no rail index).
class ShellRouteDestination {
  final String route;
  final IconData icon;
  final String Function(SkotiqLocalizations l10n) label;

  /// Optional short form for the phone bottom-nav slots; `null` falls back to
  /// [label].
  final String Function(SkotiqLocalizations l10n)? shortLabel;

  /// The label the phone bottom nav renders.
  String bottomNavLabel(SkotiqLocalizations l10n) =>
      (shortLabel ?? label)(l10n);

  const ShellRouteDestination({
    required this.route,
    required this.icon,
    required this.label,
    this.shortLabel,
  });
}

/// Canonical shell routes shared by the rail, the bottom nav, the command
/// palette and the GoRouter helpers.
abstract final class ShellNavigation {
  ShellNavigation._();

  /// The rail, in rail order, grouped Observe / Prepare / Review.
  ///
  /// Settings is deliberately NOT here: it lives in the top bar, because it is
  /// a place you go to change the app rather than a place you observe from.
  /// Folded destinations resolve through [primaryIndexForLocation]'s alias
  /// table or the command palette: Framing / Planetarium and Your Sky /
  /// Constellation are Plan tabs, Science and Transients are Analytics tabs,
  /// and Session review / Mosaic / Stack result belong to Darkroom.
  static const List<ShellPrimaryDestination> primaryDestinations = [
    ShellPrimaryDestination(
      route: '/dashboard',
      icon: LucideIcons.moonStar,
      label: _navTonight,
      group: ShellNavGroup.observe,
    ),
    ShellPrimaryDestination(
      route: '/imaging',
      icon: LucideIcons.camera,
      label: _navImaging,
      group: ShellNavGroup.observe,
    ),
    ShellPrimaryDestination(
      route: '/sequencer',
      icon: LucideIcons.listOrdered,
      label: _navSequencer,
      group: ShellNavGroup.observe,
    ),
    ShellPrimaryDestination(
      route: '/guiding',
      icon: LucideIcons.crosshair,
      label: _navGuiding,
      group: ShellNavGroup.observe,
    ),
    ShellPrimaryDestination(
      route: '/planner',
      icon: LucideIcons.compass,
      label: _navPlan,
      group: ShellNavGroup.prepare,
    ),
    ShellPrimaryDestination(
      route: '/equipment',
      icon: LucideIcons.plug,
      label: _navEquipment,
      group: ShellNavGroup.prepare,
    ),
    ShellPrimaryDestination(
      route: '/flat-wizard',
      icon: LucideIcons.sun,
      label: _navFlatWizard,
      group: ShellNavGroup.prepare,
    ),
    ShellPrimaryDestination(
      route: '/weather',
      icon: LucideIcons.cloudSun,
      label: _navWeather,
      group: ShellNavGroup.prepare,
    ),
    ShellPrimaryDestination(
      route: '/darkroom',
      icon: LucideIcons.aperture,
      label: _navDarkroom,
      group: ShellNavGroup.review,
    ),
    ShellPrimaryDestination(
      route: '/analytics',
      icon: LucideIcons.barChart3,
      label: _navAnalytics,
      group: ShellNavGroup.review,
    ),
  ];

  static const ShellPrimaryDestination settings = ShellPrimaryDestination(
    route: '/settings',
    icon: LucideIcons.settings,
    label: _settingsTitle,
    group: ShellNavGroup.prepare,
  );

  /// The five phone bottom-nav slots are four routes plus "More"; the fifth
  /// slot is the overflow sheet, which the bar renders itself.
  static const List<ShellRouteDestination> bottomNavigationDestinations = [
    ShellRouteDestination(
      route: '/dashboard',
      icon: LucideIcons.moonStar,
      label: _navTonight,
    ),
    ShellRouteDestination(
      route: '/imaging',
      icon: LucideIcons.camera,
      label: _navImaging,
      shortLabel: _navImagingShort,
    ),
    ShellRouteDestination(
      route: kSequencerRoute,
      icon: LucideIcons.listOrdered,
      label: _navSequencer,
      shortLabel: _navSequencerShort,
    ),
    ShellRouteDestination(
      route: '/guiding',
      icon: LucideIcons.crosshair,
      label: _navGuiding,
      shortLabel: _navGuidingShort,
    ),
  ];

  /// Everything the More sheet lists: every primary destination without a
  /// fixed slot (Plan, Equipment, Flat wizard, Weather, Darkroom, Analytics) plus
  /// [settings], which has no rail slot either.
  static List<ShellPrimaryDestination> get overflowDestinations {
    final bottomRoutes =
        bottomNavigationDestinations.map((d) => d.route).toSet();
    return [
      for (final dest in primaryDestinations)
        if (!bottomRoutes.contains(dest.route)) dest,
      settings,
    ];
  }

  static final List<String> primaryRoutes =
      primaryDestinations.map((d) => d.route).toList(growable: false);

  /// Routes that are not rail destinations but whose screen belongs to one.
  ///
  /// Consulted BEFORE the prefix walk, because a prefix walk cannot answer
  /// these: `/session-review` shares no prefix with `/darkroom`, and
  /// `/settings` shares one with nothing at all yet must light nothing. A
  /// value of -1 means "no rail selection" — the shell renders nothing
  /// highlighted rather than picking a plausible-looking item, because a lit
  /// rail item is a statement about where the operator is.
  static const Map<String, String?> _routeAliases = {
    '/session-review': '/darkroom',
    '/stack-result': '/darkroom',
    '/mosaic': '/darkroom',
    '/polar-alignment': '/equipment',
    '/tonight': '/dashboard',
    '/settings': null,
    '/onboarding': null,
    '/pairing': null,
    '/replay': null,
    '/diagnostics': null,
  };

  /// Index of the primary destination that HOSTS [location], or -1 when none
  /// does.
  ///
  /// Sub-routes resolve to their host: `/imaging/preview/42` (the image-ready
  /// deep link) is Imaging.
  static int primaryIndexForLocation(String location) {
    final path = _normalizePath(location);
    for (final entry in _routeAliases.entries) {
      if (path == entry.key || path.startsWith('${entry.key}/')) {
        final target = entry.value;
        return target == null ? -1 : primaryRoutes.indexOf(target);
      }
    }
    final exact = primaryRoutes.indexOf(path);
    if (exact >= 0) return exact;
    for (var i = 0; i < primaryRoutes.length; i++) {
      if (locationIsUnder(path, primaryRoutes[i])) return i;
    }
    return -1;
  }

  /// True when [location] is [route] itself or a route nested beneath it.
  ///
  /// Segment-aware: `/planner-archive` is not under `/planner`.
  static bool locationIsUnder(String location, String route) {
    final path = _normalizePath(location);
    return path == route || path.startsWith('$route/');
  }

  static String? primaryRouteForIndex(int index) {
    if (index < 0 || index >= primaryRoutes.length) return null;
    return primaryRoutes[index];
  }

  static bool isBottomNavRoute(String location) {
    final path = _normalizePath(location);
    return bottomNavigationDestinations.any((d) => d.route == path);
  }

  static String _normalizePath(String location) {
    final uri = Uri.tryParse(location);
    if (uri != null && uri.path.isNotEmpty) {
      return uri.path;
    }
    return location.split('?').first;
  }

  /// Kept beside the destination list rather than imported from the sequencer
  /// screen: this file is the router's nav contract and must not depend on a
  /// screen to state one of its own routes.
  static const String kSequencerRoute = '/sequencer';

  static String _navTonight(SkotiqLocalizations l10n) =>
      l10n.text('navTonight');
  static String _navEquipment(SkotiqLocalizations l10n) =>
      l10n.text('navEquipment');
  static String _navImaging(SkotiqLocalizations l10n) =>
      l10n.text('navImaging');
  static String _navImagingShort(SkotiqLocalizations l10n) =>
      l10n.text('navImagingShort');
  static String _navSequencer(SkotiqLocalizations l10n) =>
      l10n.text('navSequencer');
  static String _navSequencerShort(SkotiqLocalizations l10n) =>
      l10n.text('navSequencerShort');
  static String _navGuiding(SkotiqLocalizations l10n) =>
      l10n.text('navGuiding');
  static String _navGuidingShort(SkotiqLocalizations l10n) =>
      l10n.text('navGuidingShort');
  static String _navPlan(SkotiqLocalizations l10n) => l10n.text('navPlan');
  static String _navFlatWizard(SkotiqLocalizations l10n) =>
      l10n.text('navFlatWizard');
  static String _navWeather(SkotiqLocalizations l10n) =>
      l10n.text('navWeather');
  static String _navDarkroom(SkotiqLocalizations l10n) =>
      l10n.text('navDarkroom');
  static String _navAnalytics(SkotiqLocalizations l10n) =>
      l10n.text('navAnalytics');
  static String _settingsTitle(SkotiqLocalizations l10n) =>
      l10n.text('settingsTitle');
}

/// The rail group headings, in rail order.
extension ShellNavGroupLabel on ShellNavGroup {
  String label(SkotiqLocalizations l10n) => switch (this) {
        ShellNavGroup.observe => l10n.text('navGroupObserve'),
        ShellNavGroup.prepare => l10n.text('navGroupPrepare'),
        ShellNavGroup.review => l10n.text('navGroupReview'),
      };
}
