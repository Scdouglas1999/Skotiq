import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'narrator_card.dart';
import 'narrator_explainers.dart';

/// Opens the Night Narrator detail sheet for [event] as a modal bottom sheet.
///
/// Shows the full headline and body, an enlarged evidence visualization, a
/// "why this matters" explainer (from [narratorExplainers]), and an optional
/// action button (from [narratorActions]) that deep-links to Diagnostics,
/// science Analytics, or grader settings. When no explainer/action exists for
/// the event type the respective block is simply omitted.
Future<void> showNarratorDetailSheet(
  BuildContext context,
  NarratorEvent event,
) {
  final colors = SkotiqColors.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(SkotiqTokens.radiusLg),
      ),
    ),
    builder: (sheetContext) => _NarratorDetailSheet(event: event),
  );
}

class _NarratorDetailSheet extends StatelessWidget {
  final NarratorEvent event;

  const _NarratorDetailSheet({required this.event});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final accent = NarratorVisuals.accentFor(event.severity, colors);
    final icon = NarratorVisuals.iconFor(event.category);
    final explainer = narratorExplainerFor(event.eventType);
    final action = narratorActionFor(event.eventType);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          SkotiqTokens.spaceLg,
          SkotiqTokens.spaceMd,
          SkotiqTokens.spaceLg,
          SkotiqTokens.spaceLg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Grab handle.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
                decoration: BoxDecoration(
                  color: colors.border,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusXs),
                ),
              ),
            ),

            // Category + severity chip row.
            Row(
              children: [
                Icon(icon, size: 18, color: accent),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(
                  _categoryLabel(event.category),
                  style: SkotiqTypography.labelStrongSm.copyWith(
                    color: accent,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                if (event.pinned)
                  Text(
                    'PINNED',
                    style: SkotiqTypography.labelQuiet.copyWith(
                      color: colors.textMuted,
                      letterSpacing: 0.8,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),

            // Headline.
            Text(
              event.headline,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: SkotiqTypography.fontSize14,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),

            // Body.
            if (event.body != null && event.body!.isNotEmpty) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                event.body!,
                style: SkotiqTypography.body.copyWith(
                  color: colors.textSecondary,
                  height: 1.45,
                ),
              ),
            ],

            // Enlarged evidence viz.
            if (event.evidence != null) ...[
              const SizedBox(height: SkotiqTokens.spaceLg),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusMd),
                  border:
                      Border.all(color: colors.border.withValues(alpha: 0.6)),
                ),
                child: Align(
                  alignment: Alignment.center,
                  child: NarratorEvidenceViz(
                    evidence: event.evidence!,
                    accent: accent,
                    emphasized: event.severity == NarratorSeverity.celebrate,
                    large: true,
                  ),
                ),
              ),
            ],

            // "Why this matters" explainer.
            if (explainer != null) ...[
              const SizedBox(height: SkotiqTokens.spaceLg),
              Text(
                'WHY THIS MATTERS',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: colors.textMuted,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                explainer,
                style: SkotiqTypography.body.copyWith(
                  color: colors.textSecondary,
                  height: 1.5,
                ),
              ),
            ],

            // Action button.
            if (action != null) ...[
              const SizedBox(height: SkotiqTokens.spaceLg),
              SizedBox(
                width: double.infinity,
                child: SkotiqButton(
                  label: action.label,
                  onPressed: () {
                    Navigator.of(context).pop();
                    context.push(action.route);
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _categoryLabel(NarratorCategory category) {
    return switch (category) {
      NarratorCategory.discovery => 'DISCOVERY',
      NarratorCategory.milestone => 'MILESTONE',
      NarratorCategory.conditions => 'CONDITIONS',
      NarratorCategory.equipment => 'EQUIPMENT',
      NarratorCategory.quality => 'QUALITY',
    };
  }
}
