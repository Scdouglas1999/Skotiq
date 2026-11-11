/// Every place the app can show, declared once.
///
/// The router, the rail and phone bar, the command palette, the help menu,
/// the tour and every in-app link read their paths from [AppRoute] and build
/// their locations with [AppRoutes], so a path or a query parameter name is
/// written in this file and nowhere else.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' show AppScreen, TutorialCategory;

import '../localization/skotiq_localizations.dart';
import '../screens/analytics/analytics_route.dart';
import '../screens/darkroom/darkroom_route.dart';
import '../screens/planner/planner_route.dart';
import '../screens/sequencer/sequencer_route.dart';
import '../screens/settings/settings_sections.dart';

/// The three things an operator does with this app, in the order a night runs.
///
/// The rail is grouped by them rather than being one flat list, because a flat
/// list makes "Weather" and "Guiding" look like peers of equal weight when one
/// is a thing you check before you start and the other is a thing you watch
/// while running.
enum ShellNavGroup { observe, prepare, review }

/// Floating shell surfaces a screen can carry itself, so the shell leaves its
/// own copy off that screen.
enum ShellOverlay {
  /// Pause, stop and skip for a running sequence.
  runControls,

  /// Autofocus progress.
  autofocus,

  /// The live polar alignment frame and its Stop.
  polarAlignmentRun,
}

/// A route's name as the operator reads it.
sealed class RouteLabel {
  const RouteLabel();

  String of(SkotiqLocalizations l10n);
}

/// A name from the translation table.
final class TranslatedLabel extends RouteLabel {
  const TranslatedLabel(this.key);

  final String key;

  @override
  String of(SkotiqLocalizations l10n) => l10n.text(key);
}

/// A name the screen itself shows in English only.
final class EnglishLabel extends RouteLabel {
  const EnglishLabel(this.text);

  final String text;

  @override
  String of(SkotiqLocalizations l10n) => text;
}

/// Every route, one declaration each.
///
/// The rail destinations come first, in rail order; the palette lists the
/// rail and then every route marked [palette], in declaration order. The last
/// group only redirects: each path once was a screen of its own and stays so
/// old links, notifications and docs still land.
enum AppRoute {
  tonight(
    '/dashboard',
    label: TranslatedLabel('navTonight'),
    icon: LucideIcons.moonStar,
    group: ShellNavGroup.observe,
    screen: AppScreen.dashboard,
    tour: TutorialCategory.dashboardTour,
    showsItself: {ShellOverlay.runControls, ShellOverlay.autofocus},
  ),
  imaging(
    '/imaging',
    label: TranslatedLabel('navImaging'),
    shortLabel: TranslatedLabel('navImagingShort'),
    icon: LucideIcons.camera,
    group: ShellNavGroup.observe,
    screen: AppScreen.imaging,
    tour: TutorialCategory.imagingTour,
  ),
  sequencer(
    '/sequencer',
    label: TranslatedLabel('navSequencer'),
    shortLabel: TranslatedLabel('navSequencerShort'),
    icon: LucideIcons.listOrdered,
    group: ShellNavGroup.observe,
    screen: AppScreen.sequencer,
    tour: TutorialCategory.sequencerTour,
    showsItself: {ShellOverlay.runControls},
  ),
  guiding(
    '/guiding',
    label: TranslatedLabel('navGuiding'),
    shortLabel: TranslatedLabel('navGuidingShort'),
    icon: LucideIcons.crosshair,
    group: ShellNavGroup.observe,
    screen: AppScreen.guiding,
    tour: TutorialCategory.guidingTour,
  ),
  planner(
    '/planner',
    label: TranslatedLabel('navPlan'),
    icon: LucideIcons.compass,
    group: ShellNavGroup.prepare,
    screen: AppScreen.planner,
  ),
  equipment(
    '/equipment',
    label: TranslatedLabel('navEquipment'),
    icon: LucideIcons.plug,
    group: ShellNavGroup.prepare,
    screen: AppScreen.equipment,
    tour: TutorialCategory.equipmentTour,
  ),
  flatWizard(
    '/flat-wizard',
    label: TranslatedLabel('navFlatWizard'),
    icon: LucideIcons.sun,
    group: ShellNavGroup.prepare,
    keywords: ['flat', 'calibration', 'wizard'],
    screen: AppScreen.flatWizard,
    tour: TutorialCategory.flatWizardTour,
  ),
  weather(
    '/weather',
    label: TranslatedLabel('navWeather'),
    icon: LucideIcons.cloudSun,
    group: ShellNavGroup.prepare,
    screen: AppScreen.weather,
    tour: TutorialCategory.weatherTour,
  ),
  darkroom(
    '/darkroom',
    label: TranslatedLabel('navDarkroom'),
    icon: LucideIcons.aperture,
    group: ShellNavGroup.review,
    screen: AppScreen.darkroom,
  ),
  analytics(
    '/analytics',
    label: TranslatedLabel('navAnalytics'),
    icon: LucideIcons.barChart3,
    group: ShellNavGroup.review,
    screen: AppScreen.analytics,
    tour: TutorialCategory.analyticsTour,
  ),

  settings(
    '/settings',
    label: TranslatedLabel('settingsTitle'),
    icon: LucideIcons.settings,
    palette: true,
    screen: AppScreen.settings,
    tour: TutorialCategory.settingsTour,
  ),
  plateSolvingSettings('/settings/plate-solving', screen: AppScreen.settings),
  polarAlignment(
    '/polar-alignment',
    label: EnglishLabel('Polar alignment'),
    icon: LucideIcons.compass,
    palette: true,
    keywords: ['polar', 'align', 'drift', 'tppa'],
    tour: TutorialCategory.polarAlignmentTour,
    showsItself: {ShellOverlay.polarAlignmentRun},
  ),

  /// One-tap "image this target tonight": pick, frame, plan, go.
  oneTapTonight(
    '/tonight',
    label: EnglishLabel("Image tonight's best target"),
    icon: LucideIcons.moonStar,
    palette: true,
    keywords: ['one tap', 'best', 'tonight', 'automatic', 'start'],
  ),

  /// Past runs on the linked host, replayed as a timeline.
  sessionReplay(
    '/session-replay',
    label: TranslatedLabel('navSessionReplay'),
    icon: LucideIcons.history,
    palette: true,
    keywords: ['replay', 'history', 'past', 'night', 'run', 'timeline'],
  ),
  sessionReplayRun('/session-replay/:runId'),

  /// One night (`?session=`) or every night of one target (`?target=`).
  sessionReview(
    '/session-review',
    label: EnglishLabel('Session review'),
    icon: LucideIcons.clipboardList,
    palette: true,
    keywords: ['session', 'review', 'night', 'report'],
  ),
  mosaicProjects(
    '/mosaic',
    label: EnglishLabel('Mosaic'),
    icon: LucideIcons.layoutGrid,
    palette: true,
    keywords: ['mosaic', 'panel', 'tile'],
  ),
  mosaicProject('/mosaic/:id'),

  /// A route, not a `Navigator.push`, so a rail click replaces it like every
  /// other page instead of leaving it on screen above a location that changed
  /// underneath it.
  pairing(
    '/pairing',
    label: TranslatedLabel('pairingTitle'),
    icon: LucideIcons.smartphone,
    palette: true,
    keywords: ['pair', 'phone', 'remote', 'device'],
  ),

  /// Analytics > Diagnostics. Listed in the palette under its own name.
  diagnostics(
    '/diagnostics',
    label: TranslatedLabel('analyticsDiagnostics'),
    icon: LucideIcons.stethoscope,
    palette: true,
    keywords: ['diagnostics', 'logs', 'dump', 'support'],
    screen: AppScreen.diagnostics,
  ),

  /// The bug-report bundle. Not under /settings so support links can reach it
  /// directly.
  diagnosticsDump('/diagnostics/dump', screen: AppScreen.diagnostics),

  /// `image_ready` notification taps.
  imagingPreview('/imaging/preview/:imageId', screen: AppScreen.imaging),

  /// One Stack-and-Share result (`?id=`).
  stackResult('/stack-result'),

  /// The decision scrubber for one run. A route for the same reason as
  /// [pairing].
  replay('/replay/:runId'),

  /// Renders Tonight with the first-night wizard open over it.
  firstNightWizard('/tutorial/first-night'),

  /// First-run equipment setup, outside the shell so the rail does not
  /// distract a new user.
  onboarding('/onboarding', inShell: false),

  planetarium(
    '/planetarium',
    label: TranslatedLabel('plannerTabPlanetarium'),
    screen: AppScreen.planetarium,
    tour: TutorialCategory.planetariumTour,
  ),
  framing(
    '/framing',
    label: TranslatedLabel('plannerTabFraming'),
    screen: AppScreen.framing,
    tour: TutorialCategory.framingTour,
  ),
  science('/science', screen: AppScreen.science),
  transients('/transients', screen: AppScreen.transients),
  yourSky('/your-sky'),
  constellation('/constellation'),
  collaborativeSky('/collaborative-sky'),
  scheduler('/scheduler');

  const AppRoute(
    this.path, {
    this.label,
    this.shortLabel,
    this.icon,
    this.group,
    this.palette = false,
    this.keywords = const [],
    this.screen = AppScreen.unknown,
    this.tour,
    this.showsItself = const {},
    this.inShell = true,
  });

  /// The full path, with `:name` for a path parameter.
  final String path;

  final RouteLabel? label;

  /// The phone bottom bar's shorter form of [label].
  final RouteLabel? shortLabel;

  final IconData? icon;

  /// The rail group this route is listed under; null when it is not on the
  /// rail.
  final ShellNavGroup? group;

  /// Whether the command palette lists it. Rail destinations always are.
  final bool palette;

  /// Extra words the palette matches it by.
  final List<String> keywords;

  /// The screen smart notifications compare against.
  final AppScreen screen;

  /// The tour the help menu offers here.
  final TutorialCategory? tour;

  final Set<ShellOverlay> showsItself;

  /// False only for screens that bring their own scaffold and must not sit
  /// inside the app shell.
  final bool inShell;

  /// The route this one is nested under in the router, so going back from it
  /// lands on the parent.
  AppRoute? get parent => switch (this) {
        imagingPreview => imaging,
        plateSolvingSettings => settings,
        sessionReplayRun => sessionReplay,
        mosaicProject => mosaicProjects,
        _ => null,
      };

  /// The rail destination lit while this route is on screen, or null to light
  /// nothing. A lit rail item is a statement about where the operator is, so
  /// a route that no destination hosts lights none rather than a plausible
  /// one.
  AppRoute? get railHost => switch (this) {
        _ when group != null => this,
        imagingPreview => imaging,
        oneTapTonight => tonight,
        polarAlignment => equipment,
        sessionReview ||
        stackResult ||
        mosaicProjects ||
        mosaicProject =>
          darkroom,
        _ => null,
      };

  /// Whether this path only forwards to another location.
  bool get onlyRedirects => switch (this) {
        planetarium ||
        framing ||
        science ||
        transients ||
        yourSky ||
        constellation ||
        collaborativeSky ||
        scheduler ||
        diagnostics =>
          true,
        _ => false,
      };

  /// Where a request for [uri] on this route goes instead, or null to show
  /// the route itself.
  String? redirect(Uri uri) {
    final q = uri.queryParameters;
    return switch (this) {
      // The sky hand-off query (`?ra=&dec=&name=`) travels on to the tab.
      planetarium => _withQuery(
          AppRoutes.planner(tab: PlannerTab.planetarium), q,
          drop: 'tab'),
      framing =>
        _withQuery(AppRoutes.planner(tab: PlannerTab.framing), q, drop: 'tab'),
      // Science's own `?tab=` names what is now the Science view.
      science => AppRoutes.analytics(
          tab: AnalyticsTab.science,
          scienceView: ScienceTab.fromQuery(q['tab']),
        ),
      transients => AppRoutes.observingAlerts(),
      yourSky =>
        AppRoutes.planner(tab: PlannerTab.discover, view: DiscoverView.yourSky),
      constellation => AppRoutes.planner(
          tab: PlannerTab.discover, view: DiscoverView.constellation),
      collaborativeSky => AppRoutes.planner(
          tab: PlannerTab.discover, view: DiscoverView.collaborative),
      scheduler => AppRoutes.planner(tab: PlannerTab.schedule),
      diagnostics => AppRoutes.analytics(tab: AnalyticsTab.diagnostics),
      // The calibration pages moved to the Darkroom's Calibration tab.
      settings =>
        SettingsSectionId.resolve(q['section']) == SettingsSectionId.calibration
            ? AppRoutes.darkroom(
                const DarkroomRoute(tab: DarkroomTab.calibration))
            : null,
      _ => null,
    };
  }

  /// The route [location] shows, or null when no route matches it.
  ///
  /// A path below a route that declares no such child (`/planner/queue`)
  /// resolves to that route.
  static AppRoute? of(String location) {
    final segments = _segments(location);
    AppRoute? best;
    var bestLength = -1;
    for (final route in values) {
      final pattern = _segments(route.path);
      if (pattern.length > segments.length) continue;
      if (pattern.length <= bestLength) continue;
      var matches = true;
      for (var i = 0; i < pattern.length; i++) {
        if (!pattern[i].startsWith(':') && pattern[i] != segments[i]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        best = route;
        bestLength = pattern.length;
      }
    }
    return best;
  }

  /// Whether [location] is this route or a route nested below it.
  bool contains(String location) {
    for (var route = of(location); route != null; route = route.parent) {
      if (route == this) return true;
    }
    return false;
  }

  static List<String> _segments(String location) {
    final path = Uri.tryParse(location)?.path ?? location.split('?').first;
    return [
      for (final segment in path.split('/'))
        if (segment.isNotEmpty) segment,
    ];
  }

  static String _withQuery(
    String location,
    Map<String, String> extra, {
    required String drop,
  }) {
    final uri = Uri.parse(location);
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      for (final entry in extra.entries)
        if (entry.key != drop) entry.key: entry.value,
    }).toString();
  }
}

/// A sky position handed to the planetarium or framing view as
/// `?ra=&dec=&name=`. RA is decimal hours, Dec decimal degrees.
@immutable
class SkyTarget {
  const SkyTarget({
    required this.raHours,
    required this.decDegrees,
    this.name,
  });

  final double raHours;
  final double decDegrees;
  final String? name;

  /// The target a query names, or null when it is absent or invalid.
  ///
  /// Out-of-range values are rejected rather than clamped: a link that says
  /// "Dec 130°" is a broken link, and silently showing some other patch of
  /// sky would be worse than ignoring it.
  static SkyTarget? fromQuery(Map<String, String> query) {
    final ra = double.tryParse(query['ra'] ?? '');
    final dec = double.tryParse(query['dec'] ?? '');
    if (ra == null || dec == null) return null;
    final name = query['name']?.trim();
    final target = SkyTarget(
      raHours: ra,
      decDegrees: dec,
      name: name == null || name.isEmpty ? null : name,
    );
    return target.isOnTheSky ? target : null;
  }

  /// Whether the position is a real RA/Dec.
  bool get isOnTheSky =>
      raHours >= 0 && raHours < 24 && decDegrees >= -90 && decDegrees <= 90;

  Map<String, String> get query => {
        'ra': raHours.toStringAsFixed(6),
        'dec': decDegrees.toStringAsFixed(6),
        if (name != null && name!.trim().isNotEmpty) 'name': name!.trim(),
      };
}

/// Locations for routes that take parameters. A route without any is
/// [AppRoute.path].
abstract final class AppRoutes {
  static String planner({
    PlannerTab? tab,
    DiscoverView? view,
    SkyTarget? target,
  }) =>
      _location(AppRoute.planner.path, {
        if (tab != null) 'tab': tab.word,
        if (view != null) 'view': view.word,
        ...?target?.query,
      });

  /// The planetarium centered on [target].
  static String skyAt(SkyTarget target) =>
      planner(tab: PlannerTab.planetarium, target: target);

  /// Framing with [target] loaded.
  static String framingAt(SkyTarget target) =>
      planner(tab: PlannerTab.framing, target: target);

  static String analytics({AnalyticsTab? tab, ScienceTab? scienceView}) =>
      _location(AppRoute.analytics.path, {
        if (tab != null) 'tab': tab.word,
        if (scienceView != null) 'view': scienceView.word,
      });

  /// Analytics > Science > Observing alerts.
  static String observingAlerts() =>
      analytics(tab: AnalyticsTab.science, scienceView: ScienceTab.transients);

  static String sequencer({SequencerTab? tab}) =>
      _location(AppRoute.sequencer.path, {if (tab != null) 'tab': tab.word});

  /// Settings on [section], or on whatever it last showed when null.
  static String settings([SettingsSectionId? section]) =>
      _location(AppRoute.settings.path, {
        if (section != null) 'section': section.key,
      });

  static String darkroom(DarkroomRoute route) =>
      _location(AppRoute.darkroom.path, route.query);

  /// Imaging; [firstLight] opens the first-light flow once on arrival.
  static String imaging({bool firstLight = false}) =>
      _location(AppRoute.imaging.path, {
        if (firstLight) _firstLight: '1',
      });

  /// Whether [uri] is an [imaging] location that asks for the first-light
  /// flow.
  static bool asksForFirstLight(Uri uri) =>
      uri.queryParameters[_firstLight] == '1';

  static const String _firstLight = 'firstLight';

  static String imagingPreview(String imageId) =>
      _withParam(AppRoute.imagingPreview, Uri.encodeComponent(imageId));

  static String sessionReviewOfSession(int sessionId) =>
      _location(AppRoute.sessionReview.path, {'session': '$sessionId'});

  static String sessionReviewOfTarget(int targetId) =>
      _location(AppRoute.sessionReview.path, {'target': '$targetId'});

  static String stackResult(int resultId) =>
      _location(AppRoute.stackResult.path, {'id': '$resultId'});

  static String mosaicProject(int projectId) =>
      _withParam(AppRoute.mosaicProject, '$projectId');

  static String sessionReplayRun(int runId) =>
      _withParam(AppRoute.sessionReplayRun, '$runId');

  /// One run's decision replay. The name and time window ride along so the
  /// header and the scrubber survive a reload and the back stack.
  static String replay({
    required int runId,
    required String name,
    DateTime? startedAt,
    DateTime? endedAt,
  }) =>
      _location(_withParam(AppRoute.replay, '$runId'), {
        'name': name,
        if (startedAt != null) 'started': startedAt.toIso8601String(),
        if (endedAt != null) 'ended': endedAt.toIso8601String(),
      });

  static String _location(String path, Map<String, String> query) =>
      query.isEmpty ? path : Uri(path: path, queryParameters: query).toString();

  static String _withParam(AppRoute route, String value) =>
      route.path.replaceFirst(RegExp(r':\w+'), value);
}

extension SettingsNavigation on GoRouter {
  /// Shows Settings on [section]. Works whether or not Settings is already
  /// open: the Settings screen follows every navigation to its route, so a
  /// link names its destination and nothing else.
  void goToSettings([SettingsSectionId? section]) =>
      go(AppRoutes.settings(section));
}

/// The one way to open Settings from a widget.
void openSettings(BuildContext context, [SettingsSectionId? section]) =>
    GoRouter.of(context).goToSettings(section);
