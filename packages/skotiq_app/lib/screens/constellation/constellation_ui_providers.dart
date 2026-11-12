import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

/// App-side Riverpod surface for the Constellation screens (Pillar C).
///
/// The community workflow itself lives in `constellationServiceProvider` (core);
/// these providers add the small slices of UI state the screens need on top of
/// it: the verified hub identity for the connected header, the locally-imaged
/// depth that backs the "your contribution" bar, and the persisted display
/// name / privacy choice the contribute consent flow reads and writes.

/// Clear the identity-bearing hub credentials as one settings write.
///
/// Keeping this operation shared prevents the Constellation and Collaborative
/// Sky surfaces from drifting, while [SettingsDao.setSettings] avoids exposing
/// a half-signed-out identity between four separate writes.
Future<void> clearConstellationCredentials(SettingsDao settings) {
  return settings.writeAll([
    StoreSettings.constellationHubUrl.to(''),
    StoreSettings.constellationHubToken.to(''),
    StoreSettings.constellationAccountId.to(''),
    // Mint a fresh per-install identity on the next connection instead of
    // colliding with the public key still registered on the hub account being
    // replaced.
    StoreSettings.constellationPublicKey.to(''),
  ]);
}

/// The consent sheet's words for each [ConstellationPrivacy] choice.
extension ConstellationPrivacyText on ConstellationPrivacy {
  String get label => this == ConstellationPrivacy.sums
      ? 'Share co-add sums (recommended)'
      : 'Share raw subframes';

  String get blurb => this == ConstellationPrivacy.sums
      ? 'Only the additive stack your atlas already keeps leaves this device — '
          'never your individual exposures. Others cannot recover your subs.'
      : 'Every calibrated subframe is uploaded so the hub can re-grade and '
          'reject centrally. Larger, slower, and more revealing of your rig.';
}

/// Whether the host-owned Constellation actions (Contribute, Pull & Blend,
/// Retract, Share-my-targets) are enabled on this device.
///
/// They read the LOCAL atlas and contribution receipts, which are empty on a
/// SLAVE (the backend is a [NetworkBackend]) because the host owns them — so on
/// a slave they are disabled behind a host-only notice rather than presented as
/// working controls. Browse/Join/Follow-the-night stay enabled everywhere.
///
/// Gated in this ONE provider so the detail screen, the share CTA and the
/// contribute sheet all agree on slave detection.
final isConstellationHostActionEnabledProvider = Provider<bool>((ref) {
  final backend = ref.watch(backendProvider);
  return backend.runsRigHere;
});

/// The hub identity once connectivity + tiling have been verified, or null when
/// no hub is configured. Surfaces the order-mismatch refusal as an error state.
final constellationHubInfoProvider = FutureProvider<HubInfo?>((ref) async {
  final configured = await ref.watch(constellationConfiguredProvider.future);
  if (!configured) return null;
  return ref.watch(constellationServiceProvider).signIn();
});

/// The persisted display name for this imager, or an empty string before the
/// user has signed in / chosen one.
final constellationDisplayNameProvider = FutureProvider<String>((ref) async {
  return ref
      .watch(settingsDaoProvider)
      .read(StoreSettings.constellationDisplayName);
});

/// The persisted hub account id for this imager (the id the hub records a
/// co-imaging session's owner and a baton holder against), or null before the
/// user has registered with a hub. Drives owner-only affordances — notably the
/// "End session" control, which appears only when this id equals a session's
/// [CoImagingSession.ownerAccountId] (itself emitted only to that privileged
/// caller), so a non-owner can never shut a live pool.
final constellationAccountIdProvider = FutureProvider<String?>((ref) async {
  return resolveConstellationAccountId(ref.watch(settingsDaoProvider));
});

/// The persisted contribution privacy choice (defaults to [ConstellationPrivacy.sums]).
final constellationPrivacyProvider =
    FutureProvider<ConstellationPrivacy>((ref) async {
  final stored = await ref
      .watch(settingsDaoProvider)
      .read(StoreSettings.constellationPrivacy);
  return ConstellationPrivacy.values.byName(stored);
});

/// The user's locally-imaged integration depth (seconds) inside a shared
/// target's cone — the numerator of the "your local depth" bar. Reads the
/// personal atlas coverage and sums every local tile whose centre falls within
/// the target's shared [SharedTarget.radiusDeg] cone, so the displayed overlap
/// matches the swarm radius chosen when the target was shared (and what
/// contribute ships).
final yourContributionSecondsProvider =
    FutureProvider.family<double, SharedTarget>((ref, target) async {
  final coverage = await ref.watch(skyAtlasCoverageProvider.future);
  var total = 0.0;
  for (final tile in coverage) {
    final sep = AstronomyCalculations.angularSeparation(
      ra1Deg: target.raDeg,
      dec1Deg: target.decDeg,
      ra2Deg: tile.centerRaDeg,
      dec2Deg: tile.centerDecDeg,
    );
    if (sep <= target.radiusDeg) {
      total += tile.integrationSeconds;
    }
  }
  return total;
});
