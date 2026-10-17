import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/shell/app_shell.dart';
import '../screens/dashboard/dashboard_screen.dart';
import '../screens/equipment/equipment_screen.dart';
import '../screens/imaging/imaging_screen.dart';
import '../screens/guiding/guiding_screen.dart';
import '../screens/sequencer/sequencer_screen.dart';
import '../screens/sequencer/widgets/replay_debug_screen.dart';
import '../screens/planetarium/planetarium_screen.dart';
import '../screens/framing/framing_screen.dart';
import '../screens/analytics/analytics_screen.dart';
import '../screens/darkroom/darkroom_controller.dart' show DarkroomScope;
import '../screens/darkroom/darkroom_screen.dart';
import '../screens/stack_result/stack_result_screen.dart';
import '../screens/session_review/session_review_controller.dart';
import '../screens/session_review/session_review_screen.dart';
import '../screens/flat_wizard/flat_wizard_screen.dart';
import '../screens/mosaic/mosaic_project_screen.dart';
import '../screens/mosaic/mosaic_projects_list_screen.dart';
import '../screens/weather/weather_screen.dart';
import '../screens/settings/pairing_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/settings/plate_solving_settings_screen.dart';
import '../screens/polar_alignment/polar_alignment_screen.dart';
import '../screens/transients/transients_screen.dart';
import '../screens/your_sky/your_sky_screen.dart';
import '../screens/constellation/constellation_screen.dart';
import '../screens/planner/planner_screen.dart';
import '../screens/tonight/tonight_screen.dart';
import '../screens/diagnostics/diagnostics_screen.dart';
import '../screens/diagnostics/diagnostic_dump_screen.dart';
import '../screens/tutorial/first_night_wizard_route.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../widgets/first_light/first_light_launcher.dart';
import 'page_transitions.dart';

/// Optional top-level routes registered by an app entry point (e.g. desktop
/// dev screens). Defaults to empty so mobile/web builds are unaffected.
final extraTopLevelRoutesProvider =
    Provider<List<RouteBase>>((ref) => const []);

/// Where the standalone `/planetarium` deep-link lands.
///
/// Planetarium is a Plan Tonight tab, so the standalone path redirects onto the
/// host — but it must carry its query across, because the "show in sky"
/// hand-off encodes the target as `?ra=&dec=&name=` and the planetarium view
/// parses it from whatever router state is above it. Dropping the query turns
/// "show M31 in the sky" into "open the sky wherever it was".
String planetariumRedirectLocation(Uri uri) {
  final query = uri.query;
  return '/planner?tab=planetarium${query.isEmpty ? '' : '&$query'}';
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final extraRoutes = ref.watch(extraTopLevelRoutesProvider);
  return GoRouter(
    initialLocation: '/dashboard',
    routes: [
      ...extraRoutes,
      // Phone-tailored dashboard lives outside the shell because it
      // brings its own scaffold + bottom-nav and the desktop AppShell
      // would double-up the chrome and steal the bottom 78 px from the
      // sticky sequencer footer.
      // First-run equipment onboarding wizard. Sits outside the AppShell
      // so the new user is not distracted by the side-nav while they
      // configure their first profile. `EquipmentOnboardingLauncher`
      // routes here automatically when there are no profiles yet.
      GoRoute(
        path: '/onboarding',
        name: 'onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            name: 'dashboard',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: DashboardScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          GoRoute(
            path: '/equipment',
            name: 'equipment',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: EquipmentScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          GoRoute(
            path: '/imaging',
            name: 'imaging',
            // The first-light "wow moment" is triggered post-onboarding by
            // routing to `/imaging?firstLight=1`. FirstLightQueryLauncher
            // reads that query and opens the FirstLightFlowDialog exactly
            // once on arrival (then strips the query so a rebuild or
            // back-navigation can't re-fire it). It renders ImagingScreen
            // unchanged when the query is absent, so wrapping here is inert
            // for ordinary navigation to Imaging.
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: FirstLightQueryLauncher(child: ImagingScreen()),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
            routes: [
              // Deep-link target for `image_ready` notification taps. The
              // image identifier is passed through so the imaging screen can
              // highlight the new capture; the imaging screen reads :imageId
              // from GoRouterState if it wants to scroll or focus that frame.
              GoRoute(
                path: 'preview/:imageId',
                name: 'imaging-preview',
                pageBuilder: (context, state) => const CustomTransitionPage(
                  child: ImagingScreen(),
                  transitionsBuilder: PageTransitions.slideFadeTransition,
                  transitionDuration: Duration(milliseconds: 300),
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/guiding',
            name: 'guiding',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: GuidingScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          GoRoute(
            path: kSequencerRoutePath,
            name: 'sequencer',
            pageBuilder: (context, state) => CustomTransitionPage(
              child: SequencerScreen(
                initialTabQuery: state.uri.queryParameters['tab'],
              ),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: const Duration(milliseconds: 300),
            ),
          ),
          // Planetarium is a first-class Plan Tonight tab. This standalone path
          // is kept for deep-link compatibility (notifications, legacy links,
          // and the "show in sky" hand-off, which passes `?ra=&dec=&name=`) and
          // redirects onto the Planner's Planetarium tab.
          GoRoute(
            path: '/planetarium',
            name: 'planetarium',
            redirect: (context, state) =>
                planetariumRedirectLocation(state.uri),
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: PlanetariumScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          // Framing is a first-class Plan Tonight tab. This standalone path is
          // kept for deep-link compatibility (the framing handoff passes
          // `?ra=&dec=&name=`, which the Planner forwards to the Framing tab) and
          // redirects onto the Planner's Framing tab.
          GoRoute(
            path: '/framing',
            name: 'framing',
            redirect: (context, state) {
              // Preserve any target hand-off query (?ra=&dec=&name=) so a
              // "send to framing" deep-link still lands on the framed target.
              final q = state.uri.query;
              return '/planner?tab=framing${q.isEmpty ? '' : '&$q'}';
            },
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: FramingScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          GoRoute(
            path: '/analytics',
            name: 'analytics',
            pageBuilder: (context, state) {
              final tabQuery = state.uri.queryParameters['tab'];
              // `?view=` selects the inner science sub-view (workspace / first
              // light / observing alerts) when the Science tab is shown — fed by
              // the /science and /transients redirects.
              final viewQuery = state.uri.queryParameters['view'];
              return CustomTransitionPage(
                child: AnalyticsScreen(
                  initialTabQuery: tabQuery,
                  initialScienceView: viewQuery,
                ),
                transitionsBuilder: PageTransitions.slideFadeTransition,
                transitionDuration: const Duration(milliseconds: 300),
              );
            },
          ),
          // Science is folded into Analytics → Science (nested Workspace / First
          // Light / Observing Alerts). This standalone path is kept for deep-link
          // compatibility and redirects onto the Analytics Science tab, mapping
          // its `?tab=` sub-view onto the Analytics `?view=` param.
          // Redirect-only by design: go_router short-circuits a route whose
          // redirect returns non-null, so any builder here would be unreachable
          // code that reads like a live screen.
          GoRoute(
            path: '/science',
            name: 'science',
            redirect: (context, state) {
              final sub = state.uri.queryParameters['tab'];
              return '/analytics?tab=science${sub == null ? '' : '&view=$sub'}';
            },
          ),
          // Stack-and-Share result viewer. Reached from `image_ready` /
          // stack-complete notifications and the recent-results gallery via
          // `/stack-result?id=<rowId>`. The `id` query param is the
          // `StackAndShareResult` row id; we parse it defensively because the
          // route can be deep-linked. When the param is absent or not a valid
          // int we hand the screen a sentinel id (`-1`) that can never match an
          // autoincrement row, so the viewer renders its EmptyState ("Result
          // not found") instead of crashing — surfacing the bad link honestly
          // rather than silently swallowing it.
          GoRoute(
            path: '/stack-result',
            name: 'stack-result',
            pageBuilder: (context, state) {
              final idParam = state.uri.queryParameters['id'];
              final resultId = int.tryParse(idParam ?? '') ?? -1;
              return CustomTransitionPage(
                child: StackResultScreen(resultId: resultId),
                transitionsBuilder: PageTransitions.slideFadeTransition,
                transitionDuration: const Duration(milliseconds: 300),
              );
            },
          ),
          // Remote-connection pairing. A ROUTE, not a `Navigator.push` — that
          // is the whole point. An imperative push sits above the routed child
          // while the nav rail stays visible and clickable beside it: a rail
          // click would repaint that row as selected and swap the routed child
          // underneath, leaving Pairing on screen indefinitely with only its
          // own back arrow as the way out, landing on whatever destination the
          // rail silently re-pointed to. As a shell route, `context.go` from
          // the rail replaces the whole match list — the imperative push
          // included — so the rail's claim comes true.
          GoRoute(
            path: '/pairing',
            name: 'pairing',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: PairingScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          // Session Review / Morning Report. Reached from the run-completion
          // path, the analytics session list, and "image ready" notifications
          // via `/session-review?session=<id>` (one night) or
          // `/session-review?target=<id>` (all of a target's subs, multi-night).
          // A `session` param takes precedence; when neither is a valid int the
          // screen falls back to a sentinel session id (`-1`) and renders its
          // empty state rather than crashing on a deep link.
          GoRoute(
            path: '/session-review',
            name: 'session-review',
            pageBuilder: (context, state) {
              final sessionId =
                  int.tryParse(state.uri.queryParameters['session'] ?? '');
              final targetId =
                  int.tryParse(state.uri.queryParameters['target'] ?? '');
              final scope = sessionId != null
                  ? SessionReviewScope.session(sessionId)
                  : (targetId != null
                      ? SessionReviewScope.target(targetId)
                      : const SessionReviewScope.session(-1));
              return CustomTransitionPage(
                child: SessionReviewScreen(scope: scope),
                transitionsBuilder: PageTransitions.slideFadeTransition,
                transitionDuration: const Duration(milliseconds: 300),
              );
            },
          ),
          // The Darkroom editor. Reached from a master in the session review,
          // from the morning "your draft is ready" notification, and from the
          // recipe list, via `/darkroom?recipe=<id>` (one recipe) or
          // `/darkroom?master=<id>` (that master's newest recipe, or the offer
          // to create its first one). A `recipe` param takes precedence; a
          // query that parses as neither leaves both ids null, and the screen
          // renders its empty state rather than crashing on a bad deep link.
          //
          // Deliberately NOT a nav-rail destination: like session review, the
          // mosaic viewer and the stack result, the Darkroom is always about a
          // specific master, so a rail slot would lead to a screen with nothing
          // to open. `primaryIndexForLocation('/darkroom')` therefore answers
          // −1 and the rail lights nothing while it is up.
          GoRoute(
            path: '/darkroom',
            name: 'darkroom',
            pageBuilder: (context, state) {
              final recipeParam = state.uri.queryParameters['recipe'];
              final masterParam = state.uri.queryParameters['master'];
              final recipeId =
                  recipeParam == null ? null : int.tryParse(recipeParam);
              final masterId =
                  masterParam == null ? null : int.tryParse(masterParam);
              return CustomTransitionPage(
                child: DarkroomScreen(
                  scope: recipeId != null
                      ? DarkroomScope.recipe(recipeId)
                      : (masterId != null
                          ? DarkroomScope.master(masterId)
                          : const DarkroomScope.empty()),
                ),
                transitionsBuilder: PageTransitions.slideFadeTransition,
                transitionDuration: const Duration(milliseconds: 300),
              );
            },
          ),
          // Mosaic projects list + per-project review. The list is reachable
          // from nav / analytics; tapping a row deep-links to the review screen
          // at `/mosaic/:id`. The id is parsed defensively (a non-int falls
          // back to -1, which can never match an autoincrement row, so the
          // review screen renders its "not found" empty state rather than
          // crashing on a bad deep link).
          GoRoute(
            path: '/mosaic',
            name: 'mosaic-projects',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: MosaicProjectsListScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
            routes: [
              GoRoute(
                path: ':id',
                name: 'mosaic-project',
                pageBuilder: (context, state) {
                  final id =
                      int.tryParse(state.pathParameters['id'] ?? '') ?? -1;
                  return CustomTransitionPage(
                    child: MosaicProjectScreen(projectId: id),
                    transitionsBuilder: PageTransitions.slideFadeTransition,
                    transitionDuration: const Duration(milliseconds: 300),
                  );
                },
              ),
            ],
          ),
          // Replay Debug — the retrospective decision scrubber for one run.
          //
          // A real route rather than an imperative push onto the shell's
          // navigator: as part of the same match list, a nav-rail `go()`
          // replaces it instead of leaving it on screen above a location that
          // has already changed underneath it.
          GoRoute(
            path: '/replay/:runId',
            name: 'replay',
            pageBuilder: (context, state) {
              final runId =
                  int.tryParse(state.pathParameters['runId'] ?? '') ?? -1;
              final q = state.uri.queryParameters;
              return CustomTransitionPage(
                child: ReplayDebugScreen(
                  sequenceRunId: runId,
                  sequenceName: q['name'] ?? 'Sequence',
                  startedAt: DateTime.tryParse(q['started'] ?? ''),
                  endedAt: DateTime.tryParse(q['ended'] ?? ''),
                ),
                transitionsBuilder: PageTransitions.slideFadeTransition,
                transitionDuration: const Duration(milliseconds: 300),
              );
            },
          ),
          GoRoute(
            path: '/flat-wizard',
            name: 'flat-wizard',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: FlatWizardScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          GoRoute(
            path: '/weather',
            name: 'weather',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: WeatherScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            pageBuilder: (context, state) => CustomTransitionPage(
              // Deep-link a specific section via `?section=<key>` (see
              // kSettingsSectionIndex); null/unknown opens the first category.
              child: SettingsScreen(
                initialSection: state.uri.queryParameters['section'],
              ),
              transitionsBuilder: PageTransitions.scaleFadeTransition,
              transitionDuration: const Duration(milliseconds: 300),
            ),
            routes: [
              // Dedicated plate-solver setup page. Reachable from the
              // centering / framing / polar alignment "Plate solver not
              // configured" banners.
              GoRoute(
                path: 'plate-solving',
                name: 'settings-plate-solving',
                pageBuilder: (context, state) => const CustomTransitionPage(
                  child: PlateSolvingSettingsScreen(),
                  transitionsBuilder: PageTransitions.slideFadeTransition,
                  transitionDuration: Duration(milliseconds: 300),
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/polar-alignment',
            name: 'polar-alignment',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: PolarAlignmentScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          // Observing Alerts live under Analytics → Science. This standalone path
          // is kept for deep-link compatibility (notifications, transient alert
          // badge) and redirects onto that nested view.
          GoRoute(
            path: '/transients',
            name: 'transients',
            redirect: (context, state) =>
                '/analytics?tab=science&view=transients',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: TransientsScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          // Pillar A ("Your Sky") — the personal growing all-sky atlas. Now nested
          // under Plan Tonight → Discover; this path is kept for deep-link
          // compatibility and redirects onto that segmented view. The region
          // detail still opens as a pushed MaterialPageRoute from within the view.
          GoRoute(
            path: '/your-sky',
            name: 'your-sky',
            redirect: (context, state) => '/planner?tab=discover&view=yoursky',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: YourSkyScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          // Pillar C ("Constellation") — the community swarm surface. Now nested
          // under Plan Tonight → Discover; this path is kept for deep-link
          // compatibility and redirects onto that segmented view. Shared-target
          // detail still opens as a pushed MaterialPageRoute from within the view.
          GoRoute(
            path: '/constellation',
            name: 'constellation',
            redirect: (context, state) =>
                '/planner?tab=discover&view=constellation',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: ConstellationScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          // Collaborative Sky (6.0 pillar) — the unified distributed-imaging
          // surface (co-imaging, mosaics, shared calibration). Nested under Plan
          // Tonight → Discover; this path is kept for deep-link compatibility and
          // redirects onto that segmented view.
          GoRoute(
            path: '/collaborative-sky',
            name: 'collaborative-sky',
            // Pure deep-link redirect onto the real segmented Discover view
            // (CollaborativeSkyView). No pageBuilder: the redirect always fires,
            // so any builder here would be dead — the surface renders via the
            // Discover tab, never a standalone page.
            redirect: (context, state) =>
                '/planner?tab=discover&view=collaborative',
          ),
          GoRoute(
            path: '/planner',
            name: 'planner',
            pageBuilder: (context, state) {
              final tabQuery = state.uri.queryParameters['tab'];
              return CustomTransitionPage(
                child: PlannerScreen(initialTabQuery: tabQuery),
                transitionsBuilder: PageTransitions.slideFadeTransition,
                transitionDuration: const Duration(milliseconds: 300),
              );
            },
          ),
          // One-tap "image this target tonight" flow (Phase F). The
          // opinionated beginner landing CTA — pick → frame → Smart Night
          // plan → GO, with a single primary action. Shared by mobile +
          // desktop (same shell). Sibling to /planner; the deep planner and
          // sequencer stay fully available via the screen's "Advanced" link.
          GoRoute(
            path: '/tonight',
            name: 'tonight',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: TonightScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          // DEPRECATED: use /planner?tab=scheduler. Kept for one release for
          // deep-link compatibility — Scheduler lives inside Plan Tonight as
          // a tab.
          GoRoute(
            path: '/scheduler',
            name: 'scheduler',
            redirect: (context, state) => '/planner?tab=scheduler',
          ),
          // DEPRECATED: use /analytics?tab=diagnostics. Kept for one release
          // for deep-link compatibility.
          GoRoute(
            path: '/diagnostics',
            name: 'diagnostics',
            redirect: (context, state) => '/analytics?tab=diagnostics',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: DiagnosticsScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          // Bug-report bundle: zip up logs/profile/sequence/system info into
          // one attachment. Lives at /diagnostics/dump (not under /settings)
          // so support links can deep-link past the settings tree.
          GoRoute(
            path: '/diagnostics/dump',
            name: 'diagnostics-dump',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: DiagnosticDumpScreen(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 300),
            ),
          ),
          // First-night wizard entry. The route renders the dashboard
          // underneath and opens the wizard as a modal dialog on top —
          // this is how Settings → Help → "First Night Walkthrough" and
          // the auto-launch flow both reach the wizard. Dismissing the
          // dialog returns the user to /dashboard.
          GoRoute(
            path: '/tutorial/first-night',
            name: 'tutorial-first-night',
            pageBuilder: (context, state) => const CustomTransitionPage(
              child: FirstNightWizardRoute(),
              transitionsBuilder: PageTransitions.slideFadeTransition,
              transitionDuration: Duration(milliseconds: 200),
            ),
          ),
        ],
      ),
    ],
  );
});
