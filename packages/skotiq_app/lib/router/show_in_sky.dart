// "Show in sky" hand-off into the planetarium.
//
// The mirror image of the framing hand-off (`framingProvider` +
// `AppRoutes.framingAt`): every surface that can
// name a target — planner recommendation, candidate list, catalog search,
// dashboard, one-tap Tonight — can point the sky view at it.
//
// Two halves, both needed:
//
//  * [focusSkyOn] writes the planetarium view *state* (center + selection). It
//    is state, not an event, so it survives a cold start: the sky view reads
//    `skyViewStateProvider` on its first build. `flyToRequestProvider` is
//    deliberately NOT used here — its listener is registered inside the sky
//    view widget and only reacts to requests raised after that widget mounts,
//    so a jump made *before* navigating would be silently dropped.
//  * [showTargetInSky] does that and then navigates to the Planetarium tab
//    carrying the target as a [SkyTarget] query, so the same link also works
//    when pasted, restored, or followed from outside a live app session (the
//    planetarium view parses the query itself on mount).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

import 'app_routes.dart';

/// Whether the planner shows its Planetarium tab; the planner sets it as its
/// tab changes. Read through [skyIsOnScreen], which also checks the planner
/// is the page on show.
final plannerShowsSkyProvider = StateProvider<bool>((ref) => false);

/// Whether the planetarium is what the operator is looking at.
bool skyIsOnScreen(BuildContext context, WidgetRef ref) {
  final router = GoRouter.maybeOf(context);
  if (router == null || !ref.read(plannerShowsSkyProvider)) return false;
  return router.routerDelegate.currentConfiguration.uri.path ==
      AppRoute.planner.path;
}

/// Center the sky view on [coordinate] and select it.
///
/// Forces the equatorial frame: the caller is handing over an RA/Dec, and in
/// the horizontal frame the RA/Dec center is inert, so leaving the mode alone
/// would navigate the user to a planetarium that simply did not move.
void focusSkyOn(WidgetRef ref, CelestialCoordinate coordinate) {
  final skyView = ref.read(skyViewStateProvider.notifier);
  skyView.setViewMode(
    SkyViewMode.equatorial,
    observer: ref.read(observerLocationProvider),
    instant: ref.read(observationTimeProvider).time,
  );
  skyView.setCenter(coordinate.ra, coordinate.dec);
  ref.read(selectedObjectProvider.notifier).selectCoordinates(coordinate);
}

/// Point the planetarium at a target and go there.
void showTargetInSky(
  BuildContext context,
  WidgetRef ref, {
  required double raHours,
  required double decDegrees,
  String? name,
}) {
  final target =
      SkyTarget(raHours: raHours, decDegrees: decDegrees, name: name);
  // Seed the view before navigating so the sky is on target at first paint.
  if (target.isOnTheSky) {
    focusSkyOn(ref, CelestialCoordinate(ra: raHours, dec: decDegrees));
  }
  context.go(AppRoutes.skyAt(target));
}
