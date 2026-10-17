// Presentation helpers for the "Constellation" surface (Pillar C). Pure
// formatting — no ambient state — so the widgets stay declarative and the
// numbers read consistently against the rest of the atlas UI.

import '../your_sky/sky_atlas_format.dart';

/// Your locally-imaged depth on a shared target, framed as what you could still
/// contribute rather than an already-donated share: `2.1h available to
/// contribute (18% of swarm)`. Drops the swarm comparison when the total is
/// unknown (zero), and reads `Nothing local yet` when you hold no local depth.
String formatYourContribution({
  required double yourSeconds,
  required double swarmSeconds,
}) {
  if (yourSeconds <= 0 || !yourSeconds.isFinite) return 'Nothing local yet';
  final yours = formatIntegration(yourSeconds);
  if (swarmSeconds <= 0 || !swarmSeconds.isFinite) {
    return '$yours available to contribute';
  }
  final pct = ((yourSeconds / swarmSeconds) * 100).clamp(0, 100).round();
  return '$yours available to contribute ($pct% of swarm)';
}

/// Your share of a swarm co-add as a 0..1 fraction, clamped. Drives the
/// contribution bar; 0 when you have not contributed or the total is unknown.
double yourContributionFraction({
  required double yourSeconds,
  required double swarmSeconds,
}) {
  if (swarmSeconds <= 0 ||
      !swarmSeconds.isFinite ||
      yourSeconds <= 0 ||
      !yourSeconds.isFinite) {
    return 0.0;
  }
  return (yourSeconds / swarmSeconds).clamp(0.0, 1.0);
}

/// The "the swarm needs X" hint for a follow-the-night suggestion. Phrases the
/// shallowest dark target as an actionable nudge. [isReadyNow] gates the
/// urgency wording; [swarmSeconds] picks the shape of the ask.
String formatFollowHint({
  required String targetName,
  required bool isReadyNow,
  required bool altitudeOk,
  required double swarmSeconds,
}) {
  if (!isReadyNow) {
    if (!altitudeOk) {
      return '$targetName is below your horizon right now.';
    }
    return '$targetName is already being deepened by another imager.';
  }
  if (swarmSeconds <= 0) {
    return '$targetName is dark for you now and the swarm has no light yet — '
        'start its first photons.';
  }
  return '$targetName is dark for you now and the swarm needs more depth '
      '(${formatIntegration(swarmSeconds)} so far).';
}

/// A short hub identity label: `skotiq.local · a1b2c3d4`.
String formatHubLabel(String name, String fingerprint) {
  final shortPrint =
      fingerprint.length > 8 ? fingerprint.substring(0, 8) : fingerprint;
  if (name.isEmpty) return shortPrint.isEmpty ? 'Hub' : shortPrint;
  return shortPrint.isEmpty ? name : '$name · $shortPrint';
}

/// A user-facing message for a Constellation hub error, trimmed of the
/// `Exception:` / `ConstellationException(...)` envelope noise.
String describeConstellationError(Object error) {
  var raw = error.toString();
  const exc = 'Exception: ';
  if (raw.startsWith(exc)) raw = raw.substring(exc.length);
  // ConstellationException(kind): message  ->  message
  final marker = raw.indexOf('): ');
  if (raw.startsWith('ConstellationException(') && marker != -1) {
    raw = raw.substring(marker + 3);
  }
  return raw.isEmpty ? 'Unknown error.' : raw;
}
