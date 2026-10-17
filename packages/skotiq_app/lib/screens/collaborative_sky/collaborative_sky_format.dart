// Presentation helpers for the unified Collaborative Sky surface (6.0 pillar).
//
// Pure formatting — no ambient state — so the cards stay declarative and the
// combined-progress numbers read consistently against the rest of the atlas UI.

import 'package:skotiq_core/skotiq_core.dart';

/// Fraction of a collaborative mosaic that is finished (panels uploaded / total),
/// clamped to 0..1. Drives the combined-progress bar; 0 when the grid is unknown.
double mosaicCompletionFraction({required int uploaded, required int total}) {
  if (total <= 0) return 0.0;
  return (uploaded / total).clamp(0.0, 1.0);
}

/// `7 of 12 panels` — the combined panel-progress label for a mosaic.
String formatPanelProgress({required int uploaded, required int total}) {
  final unit = total == 1 ? 'panel' : 'panels';
  return '$uploaded of $total $unit';
}

/// `4 rigs` / `1 rig` — the contributor-count label for a co-imaging session.
String formatRigCount(int rigs) => '$rigs ${rigs == 1 ? 'rig' : 'rigs'}';

/// A de-duplicated, capped attribution credit line from contributor display
/// names: `Ada, Carl & Priya` or `Ada, Carl & 3 others`. Blank/duplicate names
/// are dropped; returns [emptyLabel] when no one is credited yet.
String formatContributorCredits(
  Iterable<String?> names, {
  String emptyLabel = 'No contributors yet',
  int maxNames = 3,
}) {
  final seen = <String>{};
  final ordered = <String>[];
  for (final raw in names) {
    final name = (raw ?? '').trim();
    if (name.isEmpty) continue;
    if (seen.add(name)) ordered.add(name);
  }
  if (ordered.isEmpty) return emptyLabel;
  if (ordered.length == 1) return ordered.first;
  if (ordered.length <= maxNames) {
    final head = ordered.sublist(0, ordered.length - 1).join(', ');
    return '$head & ${ordered.last}';
  }
  final head = ordered.take(maxNames).join(', ');
  final rest = ordered.length - maxNames;
  return '$head & $rest ${rest == 1 ? 'other' : 'others'}';
}

/// The contributor-credit line for a collaborative mosaic. Prefers the
/// authoritative, consent-aware credits the hub materialized and served from
/// `GET /v1/attribution` (via [attribution]). Falls back to the owner +
/// uploaded-panel display names embedded in the browse payload while
/// attribution is still loading or when the hub is unreachable, so the line is
/// never blank.
String mosaicContributorCredits(
  CollabMosaic mosaic, {
  ArtifactAttribution? attribution,
}) {
  final emptyLabel = mosaic.ownerDisplayName?.trim().isNotEmpty == true
      ? mosaic.ownerDisplayName!.trim()
      : 'Awaiting contributors';
  if (attribution != null && attribution.contributors.isNotEmpty) {
    return formatContributorCredits(
      attribution.displayNames,
      emptyLabel: emptyLabel,
    );
  }
  return formatContributorCredits(
    [
      mosaic.ownerDisplayName,
      ...mosaic.panels
          .where((p) => p.uploaded)
          .map((p) => p.assignedDisplayName),
    ],
    emptyLabel: emptyLabel,
  );
}

/// The contributor-credit line for a live co-imaging session. Prefers the
/// authoritative, consent-aware credits from `GET /v1/attribution` (via
/// [attribution]); falls back to the participant roster's display names while
/// that loads or when the hub is unreachable. [rigCount] is the "N rigs" label
/// shown before anyone has been credited.
String sessionContributorCredits(
  CoImagingSession session, {
  required int rigCount,
  ArtifactAttribution? attribution,
}) {
  if (attribution != null && attribution.contributors.isNotEmpty) {
    return formatContributorCredits(
      attribution.displayNames,
      emptyLabel: formatRigCount(rigCount),
    );
  }
  return formatContributorCredits(
    session.participants.map((p) => p.displayName),
    emptyLabel: formatRigCount(rigCount),
  );
}

/// The human label for a collaborative-mosaic hub status (`open` | `assembling`
/// | `complete`).
String formatMosaicStatus(String status) {
  switch (status) {
    case 'complete':
      return 'Complete';
    case 'assembling':
      return 'Assembling';
    case 'open':
    default:
      return 'Open for panels';
  }
}

/// The "just now" note for a live co-imaging combined-preview tick, keyed on the
/// SSE event [type]: a fused sub, or a rig joining, deepens the shared stack in
/// real time. Returns null for the initial `snapshot` (nothing new has happened
/// yet) or an unknown type, so the card only announces genuine live activity.
String? formatLivePreviewNote({required String? type}) {
  switch (type) {
    case 'combined-preview':
      return 'A sub just co-added · deepening live';
    case 'participant-joined':
      return 'A rig just joined · deepening live';
    default:
      return null;
  }
}

/// The live-status label for a co-imaging session, factoring the baton holder.
/// `Live · imaging now` when held, `Live · awaiting an imager` when free, or
/// `Closed` once the session ends.
String formatSessionStatus({
  required bool active,
  required String? batonHolderDisplayName,
}) {
  if (!active) return 'Closed';
  final holder = (batonHolderDisplayName ?? '').trim();
  if (holder.isNotEmpty) return 'Live · $holder imaging now';
  return 'Live · awaiting an imager';
}
