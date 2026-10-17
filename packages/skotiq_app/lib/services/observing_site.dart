import 'package:flutter_riverpod/flutter_riverpod.dart';
// skotiq_core also exports a (scheduler) TwilightTimes; these providers
// republish the planetarium one returned by twilightTimesProvider, so hide the
// core symbol to keep the name unambiguous in this file.
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Site-derived astronomy with "no observing site on record" as a first-class
/// absent value.
///
/// The planetarium's [twilightTimesProvider] and [moonInfoProvider] can never
/// answer "I don't know": given any latitude and longitude they return a
/// complete, plausible night, so with no site configured they describe a place
/// nobody is at.
///
/// These providers republish the same facts through a type that *can* say
/// unknown, so a consumer holding `null` has nothing to render instead of
/// something wrong. Consumers must gate on THESE, never on the coordinates:
/// (0, 0) is a real point off the coast of Africa, and an observer genuinely
/// there is entitled to their twilight times.
///
/// Whether a site exists at all is [appObserverLocationProvider]'s call, so the
/// whole app shares one definition and one place to improve it.
final observingSiteProvider = Provider<LocationSettings?>(
  (ref) => ref.watch(appObserverLocationProvider),
);

/// Twilight for the site on record; `null` when there is no site.
///
/// Note this is absent for a *different* reason than the individual
/// [TwilightTimes] fields being null — those mean "this site has no such
/// twilight tonight" (polar day/night), which is a real answer for a real
/// place. Consumers generally need both checks.
final siteTwilightTimesProvider = Provider<TwilightTimes?>((ref) {
  if (ref.watch(observingSiteProvider) == null) return null;
  return ref.watch(twilightTimesProvider);
});

/// Moonrise/moonset for the site on record; `null` when there is no site.
///
/// Phase and illumination are the same everywhere on Earth, so consumers keep
/// reading [moonInfoProvider] directly for those — blanking them would be its
/// own small lie.
final siteMoonTimesProvider = Provider<MoonTimes?>((ref) {
  if (ref.watch(observingSiteProvider) == null) return null;
  return ref.watch(moonInfoProvider);
});
