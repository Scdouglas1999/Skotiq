import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// The core barrel also exports a `ConstellationPrivacy` (the wire enum
// `contributeTarget` consumes). This file declares the richer app-side enum of
// the same name, so the core one is imported under a prefix to disambiguate.
import 'package:skotiq_core/skotiq_core.dart' hide ConstellationPrivacy;
import 'package:skotiq_core/skotiq_core.dart' as core show ConstellationPrivacy;

/// App-side Riverpod surface for the Constellation screens (Pillar C).
///
/// The community workflow itself lives in `constellationServiceProvider` (core);
/// these providers add the small slices of UI state the screens need on top of
/// it: the verified hub identity for the connected header, the locally-imaged
/// depth that backs the "your contribution" bar, and the persisted display
/// name / privacy choice the contribute consent flow reads and writes.

/// Settings key the chosen Constellation display name persists under.
const String constellationDisplayNameSettingKey = 'constellation.display_name';

/// Settings key the per-install stable public key persists under (random hex,
/// minted on first account registration; the self-hosted hub only needs a
/// stable opaque key, not a real keypair).
const String constellationPublicKeySettingKey = 'constellation.public_key';

/// Settings key the contribution privacy choice persists under. Wire value is
/// the [ConstellationPrivacy.name] (`sums` | `subs`); default is `sums`.
const String constellationPrivacySettingKey = 'constellation.privacy';

/// Clear the identity-bearing hub credentials as one settings write.
///
/// Keeping this operation shared prevents the Constellation and Collaborative
/// Sky surfaces from drifting, while [SettingsDao.setSettings] avoids exposing
/// a half-signed-out identity between four separate writes.
Future<void> clearConstellationCredentials(SettingsDao settings) {
  return settings.setSettings({
    constellationHubUrlSettingKey: '',
    constellationHubTokenSettingKey: '',
    constellationAccountIdSettingKey: '',
    // Mint a fresh per-install identity on the next connection instead of
    // colliding with the public key still registered on the hub account being
    // replaced.
    constellationPublicKeySettingKey: '',
  });
}

/// What a contributor sends to the hub. `sums` (default) shares only the same
/// additive accumulator the master integration already keeps — never the raw
/// individual subframes. `subs` is the heavier, more revealing option a user
/// can knowingly opt into for a hub that re-grades centrally.
enum ConstellationPrivacy {
  /// Additive co-add sums only (the `.nst` keystone bytes). Recommended.
  sums,

  /// Raw calibrated subframes. More to upload, more revealing.
  subs;

  String get label => this == ConstellationPrivacy.sums
      ? 'Share co-add sums (recommended)'
      : 'Share raw subframes';

  String get blurb => this == ConstellationPrivacy.sums
      ? 'Only the additive stack your atlas already keeps leaves this device — '
          'never your individual exposures. Others cannot recover your subs.'
      : 'Every calibrated subframe is uploaded so the hub can re-grade and '
          'reject centrally. Larger, slower, and more revealing of your rig.';

  /// The core wire enum [ConstellationService.contributeTarget] consumes. The
  /// two enums are kept name-aligned (`sums` | `subs`) so the persisted setting
  /// round-trips through either side.
  core.ConstellationPrivacy get wire => this == ConstellationPrivacy.sums
      ? core.ConstellationPrivacy.sums
      : core.ConstellationPrivacy.subs;
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
  return backend is! NetworkBackend && backend is! DisconnectedBackend;
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
  final settings = ref.watch(settingsDaoProvider);
  return (await settings.getSetting(constellationDisplayNameSettingKey)) ?? '';
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
  final settings = ref.watch(settingsDaoProvider);
  final raw = await settings.getSetting(constellationPrivacySettingKey);
  return ConstellationPrivacy.values.firstWhere(
    (p) => p.name == raw,
    orElse: () => ConstellationPrivacy.sums,
  );
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
    final sep = _angularSeparationDeg(
      target.raDeg,
      target.decDeg,
      tile.centerRaDeg,
      tile.centerDecDeg,
    );
    if (sep <= target.radiusDeg) {
      total += tile.integrationSeconds;
    }
  }
  return total;
});

/// Great-circle separation (deg) via the haversine formula.
double _angularSeparationDeg(
  double ra1Deg,
  double dec1Deg,
  double ra2Deg,
  double dec2Deg,
) {
  const deg2rad = math.pi / 180.0;
  final dRa = (ra2Deg - ra1Deg) * deg2rad;
  final dDec = (dec2Deg - dec1Deg) * deg2rad;
  final lat1 = dec1Deg * deg2rad;
  final lat2 = dec2Deg * deg2rad;
  final a = math.sin(dDec / 2) * math.sin(dDec / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dRa / 2) * math.sin(dRa / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return c / deg2rad;
}
