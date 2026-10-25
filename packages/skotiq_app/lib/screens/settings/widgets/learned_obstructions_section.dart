import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/confirm_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import 'settings_widgets.dart';

/// The obstructions runs have learned at the current site: where each began,
/// when, and on which target, with a remove per point and a clear for the
/// site. Planning treats each as blocked sky a few degrees either side of it.
class LearnedObstructionsSection extends ConsumerWidget {
  const LearnedObstructionsSection({super.key, this.isMobile = false});

  final bool isMobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final site = ref.watch(appObserverLocationProvider);
    final settingsAsync = ref.watch(frameWatchSettingsProvider);

    Widget note(String text) => Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceLg,
            vertical: SkotiqTokens.spaceSm,
          ),
          child: Text(
            text,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          ),
        );

    final intro = note(
      'When a run finds trees or a roof in front of the target, it records '
      'where the obstruction began. Planning then treats the sky within '
      '${learnedObstructionHalfWidthDeg.toStringAsFixed(0)}° of azimuth '
      'of each point, up to '
      '${learnedObstructionMarginDeg.toStringAsFixed(0)}° above it, as '
      'blocked. Your horizon mask above is not changed.',
    );

    if (site == null) {
      return SettingsSection(
        title: 'Learned obstructions',
        isMobile: isMobile,
        children: [
          intro,
          note('Set the site location to see the obstructions learned here.'),
        ],
      );
    }

    return settingsAsync.when(
      loading: () => SettingsSection(
        title: 'Learned obstructions',
        isMobile: isMobile,
        children: [intro, note('Loading learned obstructions...')],
      ),
      error: (e, _) => SettingsSection(
        title: 'Learned obstructions',
        isMobile: isMobile,
        children: [intro, note('Could not read the learned obstructions: $e')],
      ),
      data: (settings) {
        final points = settings
            .pointsForSite(site.latitude, site.longitude)
            .toList()
          ..sort((a, b) => a.azimuthDeg.compareTo(b.azimuthDeg));
        return SettingsSection(
          title: 'Learned obstructions',
          isMobile: isMobile,
          children: [
            intro,
            if (points.isEmpty)
              note('No obstructions learned at this site yet.')
            else ...[
              for (final point in points)
                SettingRow(
                  key: ValueKey(
                    'learned-obstruction-${point.azimuthDeg}-'
                    '${point.recordedAt.millisecondsSinceEpoch}',
                  ),
                  icon: LucideIcons.mountain,
                  title: describeLearnedObstructionPosition(point),
                  subtitle: describeLearnedObstructionOrigin(point),
                  trailing: Align(
                    alignment: Alignment.centerRight,
                    child: SkotiqButton(
                      label: 'Remove',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                      onPressed: () => _remove(context, ref, point),
                    ),
                  ),
                  isMobile: isMobile,
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceLg,
                  vertical: SkotiqTokens.spaceSm,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SkotiqButton(
                    label: 'Clear all',
                    icon: LucideIcons.trash2,
                    variant: ButtonVariant.destructive,
                    size: ButtonSize.small,
                    onPressed: () => _clearAll(
                      context,
                      ref,
                      site.latitude,
                      site.longitude,
                      points.length,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    LearnedObstructionPoint point,
  ) async {
    try {
      await ref
          .read(frameWatchSettingsProvider.notifier)
          .removeLearnedPoint(point);
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Could not remove the obstruction: $e');
      }
    }
  }

  Future<void> _clearAll(
    BuildContext context,
    WidgetRef ref,
    double latitude,
    double longitude,
    int count,
  ) async {
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Clear learned obstructions?',
      message: 'This forgets all $count obstruction${count == 1 ? '' : 's'} '
          'learned at this site. Planning will no longer avoid them until a '
          'run finds them again.',
      confirmLabel: 'Clear all',
      isDestructive: true,
    );
    if (!confirmed) return;
    try {
      await ref
          .read(frameWatchSettingsProvider.notifier)
          .clearLearnedPointsForSite(latitude, longitude);
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Could not clear the obstructions: $e');
      }
    }
  }
}

/// "Az 286.2°, alt 64.0°".
String describeLearnedObstructionPosition(LearnedObstructionPoint point) =>
    'Az ${point.azimuthDeg.toStringAsFixed(1)}°, '
    'alt ${point.altitudeDeg.toStringAsFixed(1)}°';

/// "NGC 891, 2026-10-24": the target, when known, and the local date.
String describeLearnedObstructionOrigin(LearnedObstructionPoint point) {
  final local = point.recordedAt.toLocal();
  final date = '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
  final target = point.targetName;
  return target == null ? 'Seen $date' : '$target, $date';
}
