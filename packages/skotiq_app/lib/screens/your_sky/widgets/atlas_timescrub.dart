import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Time-scrub control for a region's growth history.
///
/// Given the region's fold timeline (oldest first), it lays the distinct fold
/// instants out on a slider. Dragging selects an "as-of" instant; the parent
/// re-finalizes the cutout from only the folds up to that point. The rightmost
/// stop is "now" (all folds) — represented by a null [selected].
///
/// All time data is supplied by the caller (the fold rows); this widget holds no
/// ambient clock, so it is deterministic and testable.
class AtlasTimescrub extends StatelessWidget {
  /// Distinct fold instants in ascending order. May be empty.
  final List<DateTime> stops;

  /// The currently selected instant, or null for "latest / all folds".
  final DateTime? selected;

  /// Emits the chosen instant, or null when scrubbed fully to "now".
  final ValueChanged<DateTime?> onChanged;

  const AtlasTimescrub({
    super.key,
    required this.stops,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    if (stops.isEmpty) {
      return const SizedBox.shrink();
    }

    // Slider domain: [0 .. stops.length], where the final position (length)
    // means "now / all folds" (selected == null).
    final maxIndex = stops.length;
    final currentIndex = _indexForSelected();

    final atLatest = currentIndex >= maxIndex;
    final scrubLabel = atLatest
        ? 'Now'
        : _formatStopLabel(stops[currentIndex.clamp(0, stops.length - 1)]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.history,
                size: SkotiqTokens.iconSm, color: colors.textSecondary),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(
              'Time scrub',
              style: SkotiqTypography.labelSm
                  .copyWith(color: colors.textSecondary),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceSm,
                vertical: 2,
              ),
              decoration: SkotiqDecorations.chip(
                colors,
                tone: atLatest ? colors.success : colors.primary,
              ),
              child: Text(
                scrubLabel,
                style: SkotiqTypography.captionSm.copyWith(
                  color: atLatest ? colors.success : colors.primary,
                ),
              ),
            ),
          ],
        ),
        SkotiqSlider(
          value: currentIndex.toDouble(),
          min: 0,
          max: maxIndex.toDouble(),
          divisions: maxIndex,
          onChanged: (value) {
            final idx = value.round();
            if (idx >= maxIndex) {
              onChanged(null);
            } else {
              onChanged(stops[idx]);
            }
          },
        ),
        Row(
          children: [
            Text(
              _formatStopLabel(stops.first),
              style: SkotiqTypography.captionSm
                  .copyWith(color: colors.textMuted),
            ),
            const Spacer(),
            Text(
              'Now',
              style: SkotiqTypography.captionSm
                  .copyWith(color: colors.textMuted),
            ),
          ],
        ),
        if (!atLatest)
          Padding(
            padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: 'Jump to now',
                icon: LucideIcons.skipForward,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () => onChanged(null),
              ),
            ),
          ),
      ],
    );
  }

  int _indexForSelected() {
    final sel = selected;
    if (sel == null) return stops.length;
    // The selected instant should be one of the stops; find it (or the closest
    // not-after stop) so an external selection maps onto a slider position.
    for (var i = stops.length - 1; i >= 0; i--) {
      if (!stops[i].isAfter(sel)) return i;
    }
    return 0;
  }

  /// A short, stable label for a fold instant (UTC date, plus time when several
  /// folds share a day). Deterministic — no locale-dependent formatting.
  String _formatStopLabel(DateTime instant) {
    final utc = instant.toUtc();
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

/// Convenience: collapse a fold timeline into the distinct ascending instants a
/// scrubber stops on (one per fold record, in timeline order).
List<DateTime> scrubStopsFromFolds(List<SkyAtlasFoldRow> folds) {
  final seen = <int>{};
  final stops = <DateTime>[];
  for (final fold in folds) {
    // De-duplicate folds that share the same millisecond instant (a batch fold
    // writes several tile rows at once) so the scrubber has one stop per moment.
    final key = fold.foldedAt.toUtc().millisecondsSinceEpoch;
    if (seen.add(key)) {
      stops.add(fold.foldedAt.toUtc());
    }
  }
  stops.sort();
  return stops;
}
