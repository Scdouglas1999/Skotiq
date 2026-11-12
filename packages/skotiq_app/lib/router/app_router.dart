import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/shell/app_shell.dart';
import '../screens/night_control/night_control_screen.dart';
import '../screens/equipment/equipment_screen.dart';
import '../screens/imaging/imaging_screen.dart';
import '../screens/guiding/guiding_screen.dart';
import '../screens/sequencer/sequencer_screen.dart';
import '../screens/sequencer/widgets/replay_debug_screen.dart';
import '../screens/analytics/analytics_screen.dart';
import '../screens/darkroom/darkroom_route.dart' show DarkroomRoute;
import '../screens/darkroom/darkroom_screen.dart';
import '../screens/stack_result/stack_result_screen.dart';
import '../screens/session_review/session_review_controller.dart';
import '../screens/session_review/session_review_screen.dart';
import '../screens/session_replay/session_picker_screen.dart';
import '../screens/session_replay/session_replay_screen.dart';
import '../screens/flat_wizard/flat_wizard_screen.dart';
import '../screens/mosaic/mosaic_project_screen.dart';
import '../screens/mosaic/mosaic_projects_list_screen.dart';
import '../screens/weather/weather_screen.dart';
import '../screens/settings/pairing_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/settings/plate_solving_settings_screen.dart';
import '../screens/polar_alignment/polar_alignment_screen.dart';
import '../screens/planner/planner_screen.dart';
import '../screens/tonight/tonight_screen.dart';
import '../screens/diagnostics/diagnostic_dump_screen.dart';
import '../screens/tutorial/first_night_wizard_route.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../widgets/first_light/first_light_launcher.dart';
import 'app_routes.dart';
import 'page_transitions.dart';
import 'route_not_found_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoute.tonight.path,
    routes: [
      for (final route in _childrenOf(null, inShell: false)) _goRoute(route),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          for (final route in _childrenOf(null, inShell: true)) _goRoute(route),
        ],
      ),
    ],
    // Inside the shell, so the rail and the window controls stay.
    errorBuilder: (context, state) => AppShell(
      child: RouteNotFoundScreen(location: state.uri.toString()),
    ),
  );
});

Iterable<AppRoute> _childrenOf(AppRoute? parent, {required bool inShell}) =>
    AppRoute.values
        .where((route) => route.parent == parent && route.inShell == inShell);

GoRoute _goRoute(AppRoute route) {
  final parent = route.parent;
  final hasPage = !route.onlyRedirects;
  return GoRoute(
    path: parent == null
        ? route.path
        : route.path.substring(parent.path.length + 1),
    redirect: (context, state) => route.redirect(state.uri),
    // Outside the shell the platform's own page transition plays.
    builder: hasPage && !route.inShell
        ? (context, state) => _screen(route, state)
        : null,
    pageBuilder: !hasPage || !route.inShell
        ? null
        : (context, state) => CustomTransitionPage(
              child: _screen(route, state),
              transitionsBuilder: route == AppRoute.settings
                  ? PageTransitions.scaleFadeTransition
                  : PageTransitions.slideFadeTransition,
              transitionDuration: Duration(
                  milliseconds: route == AppRoute.firstNightWizard ? 200 : 300),
            ),
    routes: [
      for (final child in _childrenOf(route, inShell: route.inShell))
        _goRoute(child),
    ],
  );
}

/// An id that can never match an autoincrement row. A deep link whose id is
/// missing or not a number opens the screen on it, so the screen says the row
/// was not found instead of the link failing silently or crashing.
const int _noSuchRow = -1;

int _id(String? raw) => int.tryParse(raw ?? '') ?? _noSuchRow;

Widget _screen(AppRoute route, GoRouterState state) {
  final query = state.uri.queryParameters;
  return switch (route) {
    AppRoute.tonight => const NightControlScreen(),
    // `?firstLight=1` (sent after onboarding) opens the first-light flow once
    // on arrival; the launcher is inert without it.
    AppRoute.imaging => const FirstLightQueryLauncher(child: ImagingScreen()),
    AppRoute.imagingPreview => const ImagingScreen(),
    AppRoute.sequencer =>
      SequencerScreen(initialTab: SequencerTab.fromQuery(query['tab'])),
    AppRoute.guiding => const GuidingScreen(),
    AppRoute.planner => PlannerScreen(
        initialTab: PlannerTab.fromQuery(query['tab']),
        initialDiscoverView: DiscoverView.fromQuery(query['view']),
      ),
    AppRoute.equipment => const EquipmentScreen(),
    AppRoute.flatWizard => const FlatWizardScreen(),
    AppRoute.weather => const WeatherScreen(),
    AppRoute.darkroom => DarkroomScreen.route(DarkroomRoute.fromUri(state.uri)),
    AppRoute.analytics => AnalyticsScreen(
        initialTab: AnalyticsTab.fromQuery(query['tab']),
        initialScienceView: ScienceTab.fromQuery(query['view']),
      ),
    // `?section=<key>` opens that section; an unknown or missing key opens
    // the first one.
    AppRoute.settings => SettingsScreen(
        initialSection: SettingsSectionId.resolve(query['section']),
      ),
    AppRoute.plateSolvingSettings => const PlateSolvingSettingsScreen(),
    AppRoute.polarAlignment => const PolarAlignmentScreen(),
    AppRoute.oneTapTonight => const TonightScreen(),
    AppRoute.sessionReplay => const SessionPickerScreen(),
    AppRoute.sessionReplayRun =>
      SessionReplayScreen(runId: _id(state.pathParameters['runId'])),
    // `?session=` takes precedence over `?target=`.
    AppRoute.sessionReview => SessionReviewScreen(
        scope: switch ((
          int.tryParse(query['session'] ?? ''),
          int.tryParse(query['target'] ?? ''),
        )) {
          (final int session, _) => SessionReviewScope.session(session),
          (null, final int target) => SessionReviewScope.target(target),
          (null, null) => const SessionReviewScope.session(_noSuchRow),
        },
      ),
    AppRoute.mosaicProjects => const MosaicProjectsListScreen(),
    AppRoute.mosaicProject =>
      MosaicProjectScreen(projectId: _id(state.pathParameters['id'])),
    AppRoute.pairing => const PairingScreen(),
    AppRoute.diagnosticsDump => const DiagnosticDumpScreen(),
    AppRoute.stackResult => StackResultScreen(resultId: _id(query['id'])),
    AppRoute.replay => ReplayDebugScreen(
        sequenceRunId: _id(state.pathParameters['runId']),
        sequenceName: query['name'] ?? 'Sequence',
        startedAt: DateTime.tryParse(query['started'] ?? ''),
        endedAt: DateTime.tryParse(query['ended'] ?? ''),
      ),
    // Renders Tonight with the wizard open over it; closing the wizard
    // returns to Tonight.
    AppRoute.firstNightWizard => const FirstNightWizardRoute(),
    AppRoute.onboarding => const OnboardingScreen(),
    AppRoute.planetarium ||
    AppRoute.framing ||
    AppRoute.science ||
    AppRoute.transients ||
    AppRoute.yourSky ||
    AppRoute.constellation ||
    AppRoute.collaborativeSky ||
    AppRoute.scheduler ||
    AppRoute.diagnostics =>
      throw StateError('$route only redirects and has no page'),
  };
}
