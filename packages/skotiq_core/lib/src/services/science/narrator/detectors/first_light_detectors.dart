/// First Light detectors (Pillar B) — difference-imaging discoveries.
///
/// These read [NarratorContext.transientCandidates] (the cross-matched residuals
/// from `api_difference_image`) and turn the genuinely exciting ones into feed
/// events. Ids, severities, and evidence shapes are pinned by
/// `docs/skotiq_5_0_contracts.md`:
///
///   * `first_light.transient`  — celebrate, pinned: a clean, *unnamed* point
///     source (`catalogMatch == null`, round PSF, `newSource`). The headline
///     possible-transient.
///   * `first_light.brightening` — celebrate: a known/point source that brightened
///     by more than [BrighteningDetector.minDeltaMag].
///   * `first_light.mover`       — success: an elongated residual classified as a
///     moving streak.
///
/// Each is deduped per candidate position so a residual that persists across the
/// night's frames is announced once; `first_light.transient` additionally carries
/// a cooldown in `defaultNarratorCooldowns`.
library;

import '../../../../utils/coordinate_format.dart';
import '../../../transients/transient_candidate.dart';
import '../narrator_context.dart';
import '../narrator_detector.dart';
import '../narrator_event.dart';

/// Round a candidate sky position to a stable per-position dedupe key (~3.6"
/// grid at 4 decimal places of RA/Dec) so the same source across frames collapses
/// to one event.
String _positionKey(TransientCandidate c) =>
    '${c.tileId}:${c.ra.toStringAsFixed(4)}:${c.dec.toStringAsFixed(4)}';

/// 1. `first_light.transient` — a clean, unnamed point source: the headline
/// possible new transient. Requires [TransientCandidate.isUnknownPointSource]
/// (newSource + no catalog match + round PSF) plus a confidence floor so a
/// noisy residual does not masquerade as a discovery.
class TransientDiscoveryDetector extends NarratorDetector {
  static const double minConfidence = 0.5;
  static const double minSnr = 6.0;
  static const int maxPerTick = 3;

  @override
  String get id => 'first_light.transient';

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final out = <NarratorEventDraft>[];
    final candidates =
        ctx.transientCandidates
            .where(
              (c) =>
                  c.isUnknownPointSource &&
                  c.confidence >= minConfidence &&
                  c.snr >= minSnr,
            )
            .toList(growable: false)
          ..sort((a, b) => b.confidence.compareTo(a.confidence));

    for (final c in candidates.take(maxPerTick)) {
      out.add(
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.discovery,
          severity: NarratorSeverity.celebrate,
          headline:
              'Possible transient — a new source at '
              '${_formatRa(c.ra)} ${_formatDec(c.dec)} '
              '(SNR ${c.snr.toStringAsFixed(0)})',
          body:
              'This point source is not in the catalog and was not in your '
              'deep template of this field. Re-image to confirm, then submit '
              'it to AAVSO / TNS from the science export hub.',
          evidence: NarratorEvidence.scalar(
            value: c.snr,
            unit: 'σ',
            context: 'residual significance',
          ),
          dedupeKey: 'first_light.transient:${_positionKey(c)}',
          pinned: true,
          capturedImageId: ctx.capturedImageId,
        ),
      );
    }
    return out;
  }
}

/// 2. `first_light.brightening` — a source (usually catalog-matched) that
/// brightened beyond [minDeltaMag]. `deltaMag` is negative for brighter, so the
/// gate is `deltaMag < -minDeltaMag` (spec: `deltaMag < -0.3`).
class BrighteningDetector extends NarratorDetector {
  /// Magnitude brightening threshold (absolute). The spec gate is
  /// `deltaMag < -0.3`.
  static const double minDeltaMag = 0.3;
  static const int maxPerTick = 3;

  @override
  String get id => 'first_light.brightening';

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final out = <NarratorEventDraft>[];
    final candidates =
        ctx.transientCandidates
            .where((c) {
              final dm = c.deltaMag;
              return dm != null && dm.isFinite && dm < -minDeltaMag;
            })
            .toList(growable: false)
          ..sort((a, b) => a.deltaMag!.compareTo(b.deltaMag!));

    for (final c in candidates.take(maxPerTick)) {
      final magnitudeChange = c.deltaMag!.abs();
      final subject = c.catalogMatch ?? 'a source';
      out.add(
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.discovery,
          severity: NarratorSeverity.celebrate,
          headline:
              'Brightening detected — $subject is '
              '${magnitudeChange.toStringAsFixed(2)} Δinstr brighter than your '
              'template',
          body:
              'A source at ${_formatRa(c.ra)} ${_formatDec(c.dec)} jumped in '
              'brightness versus your deep stack. The change is an instrumental '
              '(luminance) Δmag, not standard Johnson V. Could be an outburst, '
              'flare, or nova — keep imaging to capture the light curve.',
          evidence: NarratorEvidence.delta(
            from: 0.0,
            to: c.deltaMag!,
            unit: 'Δinstr',
            direction: 'up',
          ),
          dedupeKey: 'first_light.brightening:${_positionKey(c)}',
          pinned: true,
          capturedImageId: ctx.capturedImageId,
        ),
      );
    }
    return out;
  }
}

/// 3. `first_light.mover` — an elongated residual classified as a moving streak
/// (asteroid / comet / satellite trail). Success severity (not celebrate) — it
/// is interesting but routine, and the dedicated moving-object pipeline handles
/// the astrometry.
class MoverDetector extends NarratorDetector {
  static const int maxPerTick = 3;

  /// Below this eccentricity the residual is too round for its major-axis
  /// position angle to be a meaningful trail direction — we omit the direction
  /// vector rather than draw an arrow off a near-circular shape.
  static const double _minEccentricityForDirection = 0.5;

  @override
  String get id => 'first_light.mover';

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final out = <NarratorEventDraft>[];
    final candidates =
        ctx.transientCandidates
            .where((c) => c.kind == TransientKind.movingStreak)
            .toList(growable: false)
          ..sort((a, b) => b.snr.compareTo(a.snr));

    for (final c in candidates.take(maxPerTick)) {
      out.add(
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.discovery,
          severity: NarratorSeverity.success,
          headline:
              'Moving streak in the difference at '
              '${_formatRa(c.ra)} ${_formatDec(c.dec)}',
          body:
              'An elongated residual appeared against your template — likely an '
              'asteroid, comet, or satellite. Review it on the transients tab '
              'and export the astrometry to the MPC.',
          evidence: _streakEvidence(c),
          dedupeKey: 'first_light.mover:${_positionKey(c)}',
          capturedImageId: ctx.capturedImageId,
        ),
      );
    }
    return out;
  }

  /// Evidence for a moving streak. When the residual is elongated enough for its
  /// measured major-axis [TransientCandidate.positionAngleDeg] to be a real trail
  /// direction, draw it as a compass vector (eccentricity as magnitude). When it
  /// is too round for orientation to mean anything, fall back to a scalar of the
  /// elongation alone — never a fabricated direction.
  NarratorEvidence _streakEvidence(TransientCandidate c) {
    if (c.eccentricity < _minEccentricityForDirection) {
      return NarratorEvidence.scalar(
        value: c.eccentricity,
        context: 'streak elongation',
      );
    }
    // The native difference detector measures the residual's major-axis position
    // angle (second moments), reported in [0, 180); normalise to a [0, 360)
    // compass bearing for the arrow.
    var bearing = c.positionAngleDeg % 360.0;
    if (bearing < 0) bearing += 360.0;
    return NarratorEvidence.vector(
      directionDeg: bearing,
      magnitude: c.eccentricity,
      label: 'streak elongation',
    );
  }
}

/// Format RA (degrees) as `HHhMMm` for a compact headline.
String _formatRa(double raDeg) => CoordinateFormat.raHmFromDegrees(
  raDeg,
  style: SexagesimalStyle.compactLetters,
);

/// Format Dec (degrees) as `+DD°MM'` for a compact headline.
String _formatDec(double decDeg) =>
    CoordinateFormat.decDm(decDeg, style: SexagesimalStyle.compactLetters);
