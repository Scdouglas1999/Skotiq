import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/narrator/narrator_feed.dart';

/// Cockpit "Night Narrator" tile — the dashboard surface for the Narrator's
/// session-long feed of plain-language insight cards ("the story of your
/// night").
///
/// Self-chromed like the other cockpit panels: it wraps itself in a
/// [SkotiqCard] with a `sparkles` header so the dashboard tile frame draws
/// no resting border. The feed is sessionful while a run is active (keyed off
/// [sessionStateProvider]'s `dbSessionId`) and falls back to the sessionless
/// recent feed when idle, so the tile always has something honest to show.
///
/// Caps at ~8 events with internal scrolling via [NarratorFeed.compact].
class CockpitNarrator extends ConsumerWidget {
  const CockpitNarrator({super.key});

  /// Cap height so the tile stays compact on the dense dashboard; the feed
  /// scrolls internally past this.
  static const double _maxFeedHeight = 320;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final dbSessionId = ref.watch(
      sessionStateProvider.select((s) => s.dbSessionId),
    );

    // Sessionful while a run is active; sessionless recent feed when idle.
    final AsyncValue<List<NarratorEvent>> feed = dbSessionId != null
        ? ref.watch(narratorFeedProvider(dbSessionId))
        : ref.watch(recentNarratorFeedProvider);

    return SkotiqPanel(
        padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(LucideIcons.sparkles, size: 14, color: colors.primary),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(
                  'NIGHT NARRATOR',
                  style: SkotiqTypography.eyebrow
                      .copyWith(color: colors.textMuted),
                ),
                const Spacer(),
                feed.maybeWhen(
                  data: (events) => events.isEmpty
                      ? const SizedBox.shrink()
                      : Text(
                          '${events.length}',
                          style: SkotiqTypography.withTabular(
                            SkotiqTypography.labelStrongSm.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                  orElse: () => const SizedBox.shrink(),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _maxFeedHeight),
              child: feed.when(
                data: (events) => NarratorFeed.compact(events: events),
                loading: () => const NarratorFeed.compact(
                  events: <NarratorEvent>[],
                ),
                error: (_, __) => _ErrorRow(colors: colors),
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SkotiqButton(
                  label: 'View in Science',
                  icon: LucideIcons.arrowRight,
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: () => context.go('/science'),
                ),
              ],
            ),
          ],
        ));
  }
}

/// Slim error row — keeps the tile honest if the feed stream faults rather
/// than vanishing or throwing.
class _ErrorRow extends StatelessWidget {
  final SkotiqColors colors;

  const _ErrorRow({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.alertTriangle, size: 15, color: colors.textMuted),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            "The Narrator's feed is unavailable right now.",
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
