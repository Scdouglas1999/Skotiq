import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
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
/// position up, and stores it.
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
  final attempt = await ref.read(siteLocatorProvider)(
    allowWifiScan: true,
    allowIp: true,
    mayEnableWifiRadio: mayEnableWifiRadio,
    googleApiKey: googleKey.isEmpty ? null : googleKey,
  );
  if (host.isStale) return null;
  final fix = attempt.fix;
  if (fix == null) return SiteNotFound(attempt);

  // Read now, not when the button was drawn: the elevation can be edited
  // while the consent dialog is up.
  final stored = await ref.read(appSettingsProvider.future);
  if (host.isStale) return null;
  final latitude = _rounded(fix.latitude);
  final longitude = _rounded(fix.longitude);
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
