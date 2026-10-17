import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Banner shown when image SNR has improved significantly since the last
/// annotation pass, suggesting the user re-annotate to find more objects.
class ReAnnotateSuggestionBanner extends ConsumerWidget {
  final SkotiqColors colors;

  const ReAnnotateSuggestionBanner({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestion = ref.watch(reAnnotateSuggestionProvider);

    if (!suggestion.shouldShow) {
      return const SizedBox.shrink();
    }

    final foreground = identical(colors, SkotiqColors.redNight)
        ? colors.textPrimary
        : colors.success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: SkotiqDecorations.statusChip(
        colors.success,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            SkotiqIcons.sparkle,
            size: 16,
            color: foreground,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Image quality improved ${suggestion.improvementPercent.toStringAsFixed(0)}% - '
              're-annotate to find more objects?',
              style:
                  SkotiqTypography.labelSm.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () {
              ref.read(reAnnotateSuggestionProvider.notifier).state =
                  const ReAnnotateSuggestion.none();
              ref.read(annotationServiceProvider).reAnnotate();
            },
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: SkotiqDecorations.tintedBadge(
                colors.success,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
              ),
              child: Text(
                'Re-annotate',
                style:
                    SkotiqTypography.labelStrongSm.copyWith(color: foreground),
              ),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () {
              ref.read(reAnnotateSuggestionProvider.notifier).state =
                  const ReAnnotateSuggestion.none();
            },
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                SkotiqIcons.close,
                size: 14,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
