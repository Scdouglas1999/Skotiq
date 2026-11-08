// The run's warnings, on Tonight.
//
// The run records what went wrong without stopping it (a centering that
// missed, the mount stopping at its tracking limit, a flip that could not
// happen early, guiding that could not restart) in its warning list. The
// session report showed them after the night; during it they lived only in
// the run's stats, and a client linked to the host never saw them at all.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Shown while the current or last run has warnings; one line with the
/// newest, expandable to all of them. Hiding it lasts until the run records
/// another.
///
/// What was hidden is shared state ([noticeAcknowledgmentsProvider]), not
/// this widget's: it used to live in the State, so leaving Tonight and coming
/// back showed the banner again, and hiding it on the host never reached a
/// linked client.
class NightRunWarningsBanner extends ConsumerStatefulWidget {
  const NightRunWarningsBanner({super.key});

  @override
  ConsumerState<NightRunWarningsBanner> createState() =>
      _NightRunWarningsBannerState();
}

class _NightRunWarningsBannerState
    extends ConsumerState<NightRunWarningsBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(liveSequenceStatsProvider);
    final warnings = stats?.warningMessages ?? const <String>[];
    if (stats == null || warnings.isEmpty) return const SizedBox.shrink();
    final hidden = ref.watch(
      noticeAcknowledgmentsProvider.select((acks) => acks.runWarnings),
    );
    final runStart = ref.watch(runStartedAtProvider);
    if (hidden != null && hidden.covers(runStart, warnings)) {
      return const SizedBox.shrink();
    }

    final colors = SkotiqColors.of(context);
    final newestFirst = warnings.reversed.toList(growable: false);
    final count = warnings.length;
    final title = count == 1 ? '1 run warning' : '$count run warnings';

    Widget warningText(String text, {bool oneLine = false}) => Text(
          text,
          style: SkotiqTypography.labelSm.copyWith(
            color: colors.textSecondary,
          ),
          maxLines: oneLine ? 1 : null,
          overflow: oneLine ? TextOverflow.ellipsis : null,
        );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.10),
        border: Border(
          bottom: BorderSide(color: colors.warning.withValues(alpha: 0.5)),
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.space2xl,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // On a narrow screen the newest warning takes its own line.
          final inline = constraints.maxWidth >= 560;
          final titleText = Text(
            title,
            style: SkotiqTypography.labelStrongSm.copyWith(
              color: colors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.alertTriangle,
                      size: 16, color: colors.warning),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  if (inline) ...[
                    titleText,
                    const SizedBox(width: SkotiqTokens.spaceMd),
                    Expanded(
                      child: _expanded
                          ? const SizedBox.shrink()
                          : warningText(newestFirst.first, oneLine: true),
                    ),
                  ] else
                    Expanded(child: titleText),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  SkotiqButton(
                    label: _expanded ? 'Show less' : 'Show all',
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                  IconButton(
                    tooltip: 'Hide until the next warning',
                    onPressed: () {
                      final acks =
                          ref.read(noticeAcknowledgmentsProvider.notifier);
                      acks.state =
                          acks.state.hidingRunWarnings(runStart, warnings);
                      setState(() => _expanded = false);
                    },
                    icon: const Icon(LucideIcons.x, size: 16),
                    color: colors.textSecondary,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                ],
              ),
              if (!inline && !_expanded)
                Padding(
                  padding:
                      const EdgeInsets.only(left: 16 + SkotiqTokens.spaceMd),
                  child: warningText(newestFirst.first, oneLine: true),
                ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.only(
                    left: 16 + SkotiqTokens.spaceMd,
                    top: SkotiqTokens.spaceXs,
                    bottom: SkotiqTokens.spaceXs,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final warning in newestFirst)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: SkotiqTokens.spaceXs,
                          ),
                          child: warningText(warning),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
