// "Show in sky" hand-off into the planetarium.
//
// The mirror image of the framing hand-off (`framingProvider` +
// `goNamed('framing')` / `/framing?ra=&dec=&name=`): every surface that can
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
//  * [showTargetInSky] does that and then navigates to `/planetarium` carrying
//    `?ra=&dec=&name=`, so the same link also works when pasted, restored, or
//    followed from outside a live app session (the planetarium view parses the
//    query itself on mount).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Route + query for a planetarium hand-off to [raHours] / [decDegrees].
///
/// RA is decimal hours and Dec decimal degrees — the same units the `/framing`
/// hand-off uses, so the two links are interchangeable at a call site.
String planetariumTargetLocation({
  required double raHours,
  required double decDegrees,
  String? name,
}) {
  return Uri(
    path: '/planetarium',
    queryParameters: {
      'ra': raHours.toStringAsFixed(6),
      'dec': decDegrees.toStringAsFixed(6),
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
    },
  ).toString();
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

/// Parse an inbound `?ra=&dec=` hand-off, or null when it is absent or invalid.
///
/// Out-of-range values are rejected rather than clamped: a link that says
/// "Dec 130°" is a broken link, and silently showing some other patch of sky
/// would be worse than ignoring it.
CelestialCoordinate? parseSkyTargetQuery(Map<String, String> params) {
  final raStr = params['ra'];
  final decStr = params['dec'];
  if (raStr == null || decStr == null) return null;

  final raHours = double.tryParse(raStr);
  final decDegrees = double.tryParse(decStr);
  if (raHours == null || decDegrees == null) return null;
  if (raHours < 0 || raHours >= 24) return null;
  if (decDegrees < -90 || decDegrees > 90) return null;

  return CelestialCoordinate(ra: raHours, dec: decDegrees);
}

/// Point the planetarium at a target and go there.
void showTargetInSky(
  BuildContext context,
  WidgetRef ref, {
  required double raHours,
  required double decDegrees,
  String? name,
}) {
  final coordinate = parseSkyTargetQuery({
    'ra': '$raHours',
    'dec': '$decDegrees',
  });
  // Seed the view before navigating so the sky is on target at first paint.
  if (coordinate != null) focusSkyOn(ref, coordinate);

  context.go(
    planetariumTargetLocation(
      raHours: raHours,
      decDegrees: decDegrees,
      name: name,
    ),
  );
}
