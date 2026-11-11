import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/screens/analytics/analytics_route.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_route.dart';
import 'package:skotiq_app/screens/planner/planner_route.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_route.dart';
import 'package:skotiq_app/screens/settings/settings_sections.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        AppScreen,
        FirstNightWizardModel,
        buildReadinessReport,
        darkroomActivityRoute,
        darkroomFramingRoute,
        darkroomTargetRoute,
        kNextUseSteps;

import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Every GoRoute in the tree, depth-first, with its full path.
Iterable<(String, GoRoute)> _allRoutes(
  List<RouteBase> routes, [
  String parent = '',
]) sync* {
  for (final route in routes) {
    if (route is GoRoute) {
      final full =
          route.path.startsWith('/') ? route.path : '$parent/${route.path}';
      yield (full, route);
      yield* _allRoutes(route.routes, full);
    } else {
      yield* _allRoutes(route.routes, parent);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoRouter router;
  setUp(() {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    router = container.read(appRouterProvider);
  });

  /// Where the app's real router sends [location], redirects applied.
  Future<Uri> resolve(WidgetTester tester, String location) async {
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    final match = await router.configuration.redirect(
      context,
      router.configuration.findMatch(Uri.parse(location)),
      redirectHistory: [],
    );
    expect(match.isError, isFalse, reason: '$location matched no route');
    return match.uri;
  }

  group('old links still land', () {
    testWidgets('/planetarium carries the sky target to the Planetarium tab',
        (tester) async {
      final uri =
          await resolve(tester, '/planetarium?ra=10.5&dec=41.2&name=M31');
      expect(uri.path, '/planner');
      expect(PlannerTab.fromQuery(uri.queryParameters['tab']),
          PlannerTab.planetarium);
      final target = SkyTarget.fromQuery(uri.queryParameters)!;
      expect(target.raHours, 10.5);
      expect(target.decDegrees, 41.2);
      expect(target.name, 'M31');

      expect((await resolve(tester, '/planetarium')).toString(),
          '/planner?tab=planetarium');
    });

    testWidgets('/framing carries the sky target to the Framing tab',
        (tester) async {
      final uri = await resolve(tester, '/framing?ra=5.5&dec=-5.4&name=M42');
      expect(uri.path, '/planner');
      expect(uri.queryParameters['tab'], 'framing');
      expect(SkyTarget.fromQuery(uri.queryParameters)!.name, 'M42');
    });

    testWidgets('/science opens Analytics > Science on its old sub-tab',
        (tester) async {
      expect((await resolve(tester, '/science')).toString(),
          '/analytics?tab=science');
      for (final (word, view) in [
        ('workspace', ScienceTab.workspace),
        ('firstlight', ScienceTab.firstLight),
        ('discovery', ScienceTab.firstLight),
        ('alerts', ScienceTab.transients),
      ]) {
        final uri = await resolve(tester, '/science?tab=$word');
        expect(uri.queryParameters['tab'], 'science');
        expect(ScienceTab.fromQuery(uri.queryParameters['view']), view,
            reason: '/science?tab=$word');
      }
    });

    testWidgets('/transients opens the observing alerts', (tester) async {
      expect((await resolve(tester, '/transients')).toString(),
          '/analytics?tab=science&view=transients');
    });

    testWidgets('the Discover pillars open their view', (tester) async {
      expect((await resolve(tester, '/your-sky')).toString(),
          '/planner?tab=discover&view=yoursky');
      expect((await resolve(tester, '/constellation')).toString(),
          '/planner?tab=discover&view=constellation');
      expect((await resolve(tester, '/collaborative-sky')).toString(),
          '/planner?tab=discover&view=collaborative');
    });

    testWidgets('/scheduler and /diagnostics open their tabs', (tester) async {
      expect((await resolve(tester, '/scheduler')).toString(),
          '/planner?tab=scheduler');
      expect((await resolve(tester, '/diagnostics')).toString(),
          '/analytics?tab=diagnostics');
      // The dump page sits below the old path and is a page of its own.
      expect((await resolve(tester, '/diagnostics/dump')).toString(),
          '/diagnostics/dump');
    });

    testWidgets('old calibration settings open the Darkroom Calibration tab',
        (tester) async {
      for (final key in [
        'calibration',
        'dark-library',
        'calibration-library'
      ]) {
        final uri = await resolve(tester, '/settings?section=$key');
        expect(uri.path, '/darkroom', reason: key);
        expect(DarkroomRoute.fromUri(uri).tab, DarkroomTab.calibration);
      }
      expect((await resolve(tester, '/settings?section=imaging')).toString(),
          '/settings?section=imaging');
      expect((await resolve(tester, '/settings')).toString(), '/settings');
    });

    testWidgets('every route with a page resolves to itself', (tester) async {
      for (final route in AppRoute.values) {
        if (route.onlyRedirects) continue;
        final location = route.path.replaceAll(RegExp(r':\w+'), '7');
        expect(AppRoute.of((await resolve(tester, location)).toString()), route,
            reason: location);
      }
    });
  });

  group('typed queries read back what they write', () {
    test('Plan tabs and Discover views', () {
      for (final tab in PlannerTab.values) {
        final uri = Uri.parse(AppRoutes.planner(tab: tab));
        expect(PlannerTab.fromQuery(uri.queryParameters['tab']), tab);
      }
      for (final view in DiscoverView.values) {
        final uri =
            Uri.parse(AppRoutes.planner(tab: PlannerTab.discover, view: view));
        expect(DiscoverView.fromQuery(uri.queryParameters['view']), view);
      }
      expect(AppRoutes.planner(tab: PlannerTab.schedule),
          '/planner?tab=scheduler');
      // Words older links used.
      expect(PlannerTab.fromQuery('schedule'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('WEEK'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('campaigns'), PlannerTab.projects);
      expect(PlannerTab.fromQuery('your-sky'), PlannerTab.discover);
      expect(DiscoverView.fromQuery('collab'), DiscoverView.collaborative);
      expect(PlannerTab.fromQuery('not-a-tab'), isNull);
      expect(PlannerTab.fromQuery(null), isNull);
    });

    test('Analytics tabs and Science views', () {
      for (final tab in AnalyticsTab.values) {
        final uri = Uri.parse(AppRoutes.analytics(tab: tab));
        expect(AnalyticsTab.fromQuery(uri.queryParameters['tab']), tab);
      }
      for (final view in ScienceTab.values) {
        final uri = Uri.parse(
            AppRoutes.analytics(tab: AnalyticsTab.science, scienceView: view));
        expect(ScienceTab.fromQuery(uri.queryParameters['view']), view);
      }
      expect(AnalyticsTab.fromQuery('equipment-stats'), AnalyticsTab.equipment);
      expect(ScienceTab.fromQuery('first_light'), ScienceTab.firstLight);
    });

    test('Sequencer tabs', () {
      for (final tab in SequencerTab.values) {
        final uri = Uri.parse(AppRoutes.sequencer(tab: tab));
        expect(SequencerTab.fromQuery(uri.queryParameters['tab']), tab);
      }
      expect(SequencerTab.fromQuery('RUNS'), SequencerTab.history);
      expect(SequencerTab.fromQuery('library'), SequencerTab.sequences);
      expect(SequencerTab.fromQuery('made-up'), isNull);
    });

    test('Settings sections', () {
      for (final section in SettingsSectionId.values) {
        final uri = Uri.parse(AppRoutes.settings(section));
        expect(
            SettingsSectionId.resolve(uri.queryParameters['section']), section);
      }
      expect(AppRoutes.settings(), '/settings');
    });

    test('a sky target', () {
      const target = SkyTarget(raHours: 13.5, decDegrees: 47.2, name: ' M51 ');
      final read = SkyTarget.fromQuery(
          Uri.parse(AppRoutes.skyAt(target)).queryParameters)!;
      expect(read.raHours, 13.5);
      expect(read.decDegrees, 47.2);
      expect(read.name, 'M51');
      expect(
        Uri.parse(AppRoutes.framingAt(
                const SkyTarget(raHours: 1, decDegrees: 2, name: '  ')))
            .queryParameters
            .containsKey('name'),
        isFalse,
      );
      // A link that names no real position is a broken link, not a nearby one.
      for (final query in [
        <String, String>{},
        {'ra': '13.5'},
        {'ra': 'M51', 'dec': '47.2'},
        {'ra': '24', 'dec': '47.2'},
        {'ra': '-0.1', 'dec': '47.2'},
        {'ra': '13.5', 'dec': '90.1'},
      ]) {
        expect(SkyTarget.fromQuery(query), isNull, reason: '$query');
      }
      expect(SkyTarget.fromQuery({'ra': '0', 'dec': '-90'}), isNotNull);
    });

    test('ids, the first-light flow and the replay window', () {
      expect(AppRoutes.stackResult(9), '/stack-result?id=9');
      expect(AppRoutes.sessionReviewOfSession(3), '/session-review?session=3');
      expect(AppRoutes.sessionReviewOfTarget(4), '/session-review?target=4');
      expect(AppRoutes.mosaicProject(7), '/mosaic/7');
      expect(AppRoutes.sessionReplayRun(12), '/session-replay/12');
      expect(AppRoutes.imagingPreview('a/b c'), '/imaging/preview/a%2Fb%20c');

      expect(
          AppRoutes.asksForFirstLight(
              Uri.parse(AppRoutes.imaging(firstLight: true))),
          isTrue);
      expect(
          AppRoutes.asksForFirstLight(Uri.parse(AppRoutes.imaging())), isFalse);

      final started = DateTime.utc(2026, 11, 10, 22);
      final replay = Uri.parse(
          AppRoutes.replay(runId: 5, name: 'M31 night', startedAt: started));
      expect(AppRoute.of(replay.toString()), AppRoute.replay);
      expect(replay.queryParameters['name'], 'M31 night');
      expect(DateTime.parse(replay.queryParameters['started']!), started);
      expect(replay.queryParameters.containsKey('ended'), isFalse);
    });
  });

  group('the table', () {
    test('the router registers exactly the table, nested as declared', () {
      final registered = {
        for (final (path, route) in _allRoutes(router.configuration.routes))
          path: route,
      };
      expect(registered.keys.toSet(),
          {for (final route in AppRoute.values) route.path});
      for (final route in AppRoute.values) {
        final goRoute = registered[route.path]!;
        final hasPage = goRoute.builder != null || goRoute.pageBuilder != null;
        expect(hasPage, !route.onlyRedirects,
            reason: '${route.path}: a redirect-only path has no page, and '
                'every other path has one');
      }
    });

    test('paths are unique and children sit below their parent', () {
      expect({for (final r in AppRoute.values) r.path}.length,
          AppRoute.values.length);
      for (final route in AppRoute.values) {
        expect(route.path, startsWith('/'));
        final parent = route.parent;
        if (parent != null) {
          expect(route.path, startsWith('${parent.path}/'));
        }
      }
    });

    test('every listed route can be drawn', () {
      for (final route in AppRoute.values) {
        if (route.group == null && !route.palette) continue;
        expect(route.icon, isNotNull, reason: route.path);
        expect(route.label, isNotNull, reason: route.path);
      }
    });

    test('a location resolves to its route', () {
      expect(AppRoute.of('/imaging/preview/42?x=1'), AppRoute.imagingPreview);
      expect(AppRoute.of('/mosaic/7'), AppRoute.mosaicProject);
      expect(AppRoute.of('/session-review?session=3'), AppRoute.sessionReview);
      expect(AppRoute.of('/planner/queue'), AppRoute.planner);
      expect(AppRoute.of('/planner-archive'), isNull);
      expect(AppRoute.of('/'), isNull);

      expect(AppRoute.imaging.contains('/imaging/preview/42'), isTrue);
      expect(AppRoute.settings.contains('/settings/plate-solving'), isTrue);
      expect(AppRoute.tonight.contains('/tonight'), isFalse);
    });

    test('smart notifications see the screen on show', () {
      for (final (location, screen) in [
        ('/dashboard', AppScreen.dashboard),
        ('/imaging/preview/4', AppScreen.imaging),
        ('/darkroom?master=3', AppScreen.darkroom),
        ('/settings/plate-solving', AppScreen.settings),
        ('/diagnostics/dump', AppScreen.diagnostics),
        ('/session-review?session=1', AppScreen.unknown),
      ]) {
        expect(AppRoute.of(location)!.screen, screen, reason: location);
      }
    });

    // Core models carry routes as strings (some cross the wire), so they cannot
    // name the table; this keeps them pointing at it.
    test('links written by core land on a route', () {
      final allFailing = buildReadinessReport(
        cameraConnected: false,
        mountConnected: false,
        hasProfile: true,
        locationSet: false,
        outputPathSet: false,
        plateSolverReady: false,
        darkLibraryHasCoverage: false,
        focusKnown: false,
        hasActiveProfile: true,
        assignedProfileDeviceCount: 3,
        otherAssignedProfileDeviceCount: 1,
        offlineProfileDevices: const ['Focuser'],
      );
      final locations = [
        darkroomTargetRoute('NGC 891'),
        darkroomFramingRoute('NGC 891'),
        darkroomActivityRoute,
        for (final step in kNextUseSteps) step.deepLinkRoute,
        for (final step in FirstNightWizardModel.steps)
          if (step.hasDeepLink) step.deepLinkRoute,
        for (final item in allFailing.items)
          if (item.fixRoute case final route?) route,
      ];
      expect(locations, hasLength(greaterThan(12)));
      for (final location in locations) {
        expect(AppRoute.of(location), isNotNull, reason: location);
      }
    });
  });
}
