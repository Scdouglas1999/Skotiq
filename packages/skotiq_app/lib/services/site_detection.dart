import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/backend.dart' show SkotiqBackend;
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../widgets/geolocation_consent.dart';

/// Resolves this machine's position through the positioning tiers: the
/// platform's location service, a Wi-Fi scan resolved by a positioning
/// service, then the internet (public-IP) estimate, and reports what each one
/// did. Injected so the consent, radio-power and write rules can be driven in
/// tests without a network, a GPS or a wireless card.
typedef SiteLocator = Future<PositioningAttempt> Function({
  required bool allowWifiScan,
  required bool allowIp,
  bool mayEnableWifiRadio,
  String? googleApiKey,
});

final siteLocatorProvider = Provider<SiteLocator>(
  (ref) => GeolocationService.locate,
);

/// Leaves room for every positioning tier and restoring a radio enabled for
/// this attempt, while keeping a stalled platform call from trapping the UI.
const siteDetectionTimeout = Duration(seconds: 30);

/// How far a fix may sit from the stored site before the stored elevation is
/// taken to belong to a different place. An internet estimate is accurate to
/// roughly a city.
const double sameSiteRadiusKm = 25;

/// What a Detect location did once the lookup ran.
sealed class SiteDetection {
  const SiteDetection(this.attempt);

  final PositioningAttempt attempt;
}

/// No tier found a position; [PositioningAttempt.failureMessage] says why.
final class SiteNotFound extends SiteDetection {
  const SiteNotFound(super.attempt);
}

/// A fix too coarse to stand as the observing site: an internet estimate, or
/// a location service working from the same internet address. Nothing is
/// stored; [acceptEstimatedSite] stores it once the operator says so, so an
/// estimate never feeds a run's altitude or meridian decisions unconfirmed.
final class SiteEstimated extends SiteDetection {
  const SiteEstimated(
    super.attempt, {
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;

  PositioningResult get fix => attempt.fix!;

  /// The place's name, or its coordinates.
  String get where =>
      fix.locationName ??
      '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
}

/// The site is now [latitude], [longitude]. [keptElevation] is false when the
/// stored elevation was cleared because it belonged to a different place.
final class SiteDetected extends SiteDetection {
  const SiteDetected(
    super.attempt, {
    required this.latitude,
    required this.longitude,
    required this.keptElevation,
  });

  final double latitude;
  final double longitude;
  final bool keptElevation;

  PositioningResult get fix => attempt.fix!;

  /// The place's name, or its coordinates.
  String get where =>
      fix.locationName ??
      '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
}

/// One click from "where am I" to a stored site: asks before anything leaves
/// the machine (once per session, naming each tier that will run), looks the
/// position up, and stores a precise fix. A coarse one comes back as a
/// [SiteEstimated] for the operator to accept.
///
/// A stored elevation stays only with a fix inside [sameSiteRadiusKm] of the
/// stored site, or when no site is stored yet (it is then what the operator
/// just typed); otherwise it is cleared to 0 m, the app's "not set", because
/// an elevation from another place is a wrong number refraction and horizon
/// maths would use. [mayEnableWifiRadio] is set only by the explicit "Turn
/// Wi-Fi on for a precise fix" offer, and the radio goes back off afterwards.
///
/// [onLookingUp] runs once the operator has agreed and the lookup starts.
/// Returns null when the operator declined, or when the host changed during
/// the lookup (the reading is then never applied to the replacement host).
Future<SiteDetection?> detectSite(
  BuildContext context,
  WidgetRef ref, {
  bool mayEnableWifiRadio = false,
  VoidCallback? onLookingUp,
}) async {
  final googleKey = ref.read(googleGeolocationKeyProvider).value ?? '';
  final consented = await ensureGeolocationConsent(
    context,
    ref,
    outcome: kGeolocationWritesSiteOutcome,
    googleKeyPresent: googleKey.isNotEmpty,
  );
  if (!consented || !context.mounted) return null;

  final host = ref.backendScope(alive: () => context.mounted);
  onLookingUp?.call();
  final attempt = await ref
      .read(siteLocatorProvider)(
        allowWifiScan: true,
        allowIp: true,
        mayEnableWifiRadio: mayEnableWifiRadio,
        googleApiKey: googleKey.isEmpty ? null : googleKey,
      )
      .timeout(
        siteDetectionTimeout,
        onTimeout: () => throw TimeoutException(
          'Location detection timed out. Try again, search for a place, '
          'or enter coordinates.',
        ),
      );
  if (host.isStale) return null;
  final fix = attempt.fix;
  if (fix == null) return SiteNotFound(attempt);
  final latitude = _rounded(fix.latitude);
  final longitude = _rounded(fix.longitude);
  if (!fix.isPrecise) {
    return SiteEstimated(attempt, latitude: latitude, longitude: longitude);
  }
  return _store(ref, attempt, latitude, longitude, host);
}

/// Store [estimate] as the observing site, which the operator accepted.
/// Returns null when the host changed meanwhile.
Future<SiteDetected?> acceptEstimatedSite(
  BuildContext context,
  WidgetRef ref,
  SiteEstimated estimate,
) =>
    _store(
      ref,
      estimate.attempt,
      estimate.latitude,
      estimate.longitude,
      ref.backendScope(alive: () => context.mounted),
    );

Future<SiteDetected?> _store(
  WidgetRef ref,
  PositioningAttempt attempt,
  double latitude,
  double longitude,
  AsyncScope<SkotiqBackend> host,
) async {
  // Read now, not when the button was drawn: the elevation can be edited
  // while the consent dialog is up.
  final stored = await ref.read(appSettingsProvider.future);
  if (host.isStale) return null;
  final keptElevation = !stored.hasObserverLocation ||
      _kmBetween(stored.latitude, stored.longitude, latitude, longitude) <=
          sameSiteRadiusKm;
  await ref.read(appSettingsProvider.notifier).updateLocation(
        latitude: latitude,
        longitude: longitude,
        elevation: keptElevation ? null : 0,
      );
  if (host.isStale) return null;
  return SiteDetected(
    attempt,
    latitude: latitude,
    longitude: longitude,
    keptElevation: keptElevation,
  );
}

/// Four decimals of a degree is about ten metres, finer than any lookup tier
/// places a site; the digits past it are noise in the stored site.
double _rounded(double degrees) => double.parse(degrees.toStringAsFixed(4));

double _kmBetween(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusKm = 6371.0;
  final degrees = AstronomyCalculations.angularSeparation(
    ra1Deg: lon1,
    dec1Deg: lat1,
    ra2Deg: lon2,
    dec2Deg: lat2,
  );
  return earthRadiusKm * degrees * math.pi / 180.0;
}
