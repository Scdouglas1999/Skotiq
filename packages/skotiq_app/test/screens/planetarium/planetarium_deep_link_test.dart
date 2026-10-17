// `/planetarium?ra=&dec=&name=` end to end, through the real screen.
//
// The receiving half of this hand-off existed but had no sender, and the route
// discarded the query anyway. The subtle failure mode the wiring has to avoid
// is a *cold* jump: `flyToRequestProvider`'s listener lives inside the sky view
// widget and only reacts to requests raised after it mounts, so an event-based
// hand-off would be silently dropped when the planetarium is not yet built.
// These tests therefore drive the real `PlanetariumScreen` under a real
// GoRouter and assert on `skyViewStateProvider` — the state the renderer reads
// on its first build.
//
// The companion data-level tests (link → redirect → parse) live in
// show_in_sky_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/planetarium/planetarium_screen.dart';
import 'package:skotiq_app/screens/planetarium/show_in_sky.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Future<(ProviderContainer, GoRouter)> _pumpPlanetarium(
  WidgetTester tester, {
  required String initialLocation,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  // The zenith — and so the sky view's home pose — is only defined for an
  // observer, so these cases need a site on record.
  container
      .read(observerLocationProvider.notifier)
      .setLocation(latitude: 40.0, longitude: -105.0);
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/planetarium',
        builder: (context, state) => const PlanetariumScreen(),
      ),
    ],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return (container, router);
}

/// The screen owns periodic timers (observation clock, mount-sync debounce), so
/// unmount and dispose inside the test body — `testWidgets` checks for pending
/// timers before `addTearDown` callbacks run.
Future<void> _teardown(
  WidgetTester tester,
  ProviderContainer container,
  GoRouter router,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  router.dispose();
  container.dispose();
  // Disposing the container cancels the drift query streams the screen's
  // providers were watching, and drift finishes that off in a zero-duration
  // Timer (StreamQueryStore.markAsClosed). Pump a non-zero duration to let it
  // run: a bare pump() does not advance the fake clock, so a timer scheduled
  // for *now* would still be queued when the binding checks.
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('cold start lands on the handed-off target', (tester) async {
    final (container, router) = await _pumpPlanetarium(
      tester,
      initialLocation: planetariumTargetLocation(
        raHours: 13.5,
        decDegrees: 47.2,
        name: 'M51',
      ),
    );

    final view = container.read(skyViewStateProvider);
    expect(view.centerRA, closeTo(13.5, 1e-6));
    expect(view.centerDec, closeTo(47.2, 1e-6));
    expect(container.read(selectedObjectProvider).coordinates, isNotNull);

    await _teardown(tester, container, router);
  });

  testWidgets('a warm jump moves the already-mounted sky view', (tester) async {
    // Plan Tonight keeps the planetarium built in an IndexedStack, so the
    // second navigation never re-runs initState. This is the case an
    // event-based hand-off would drop.
    final (container, router) =
        await _pumpPlanetarium(tester, initialLocation: '/planetarium');
    // The untouched default pose is the zenith, not RA 0h / Dec 0.
    final homeRa = container.read(skyViewHomeCenterProvider)!.$1;
    expect(
      container.read(skyViewStateProvider).centerRA,
      closeTo(homeRa, 0.02),
    );

    router.go(planetariumTargetLocation(
      raHours: 5.59,
      decDegrees: -5.39,
      name: 'M42',
    ));
    await tester.pump();
    await tester.pump();

    final view = container.read(skyViewStateProvider);
    expect(view.centerRA, closeTo(5.59, 1e-6));
    expect(view.centerDec, closeTo(-5.39, 1e-6));

    await _teardown(tester, container, router);
  });

  testWidgets('does not yank the view back after the user pans away',
      (tester) async {
    final (container, router) = await _pumpPlanetarium(
      tester,
      initialLocation:
          planetariumTargetLocation(raHours: 13.5, decDegrees: 47.2),
    );
    expect(container.read(skyViewStateProvider).centerRA, closeTo(13.5, 1e-6));

    container.read(skyViewStateProvider.notifier).setCenter(2, 10);
    await tester.pump();
    await tester.pump();

    final view = container.read(skyViewStateProvider);
    expect(view.centerRA, closeTo(2, 1e-6));
    expect(view.centerDec, closeTo(10, 1e-6));

    await _teardown(tester, container, router);
  });

  testWidgets('ignores an out-of-range hand-off instead of showing wrong sky',
      (tester) async {
    final (container, router) = await _pumpPlanetarium(
      tester,
      initialLocation: '/planetarium?ra=13.5&dec=200',
    );

    // The bogus hand-off must leave the view exactly where it opened — the
    // zenith — rather than move it anywhere.
    final (homeRa, homeDec) = container.read(skyViewHomeCenterProvider)!;
    final view = container.read(skyViewStateProvider);
    expect(view.centerRA, closeTo(homeRa, 0.02));
    expect(view.centerDec, closeTo(homeDec, 1e-9));
    expect(container.read(selectedObjectProvider).coordinates, isNull);

    await _teardown(tester, container, router);
  });
}
