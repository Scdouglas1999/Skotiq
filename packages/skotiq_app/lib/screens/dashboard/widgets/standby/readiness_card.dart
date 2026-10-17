import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../glass_card.dart';

/// Readiness & storage glance: connection state for the four core devices
/// (camera w/ cooler temp, mount, guider, focuser) plus free disk on the
/// capture directory. Offers a "Connect equipment" shortcut when nothing is
/// connected. Reads the same `*StateProvider` selects the command bar uses so
/// standby and the live cockpit agree.
class ReadinessCard extends ConsumerWidget {
  final SkotiqColors colors;

  const ReadinessCard({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameraConnected =
        ref.watch(cameraStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final cameraTemp =
        ref.watch(cameraStateProvider.select((s) => s.temperature));
    final mountConnected =
        ref.watch(mountStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final guiderConnected =
        ref.watch(guiderStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final focuserConnected =
        ref.watch(focuserStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;

    final nothingConnected = !cameraConnected &&
        !mountConnected &&
        !guiderConnected &&
        !focuserConnected;

    final coolerLabel = cameraConnected && cameraTemp != null
        ? '${cameraTemp.toStringAsFixed(1)}°C'
        : null;

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.plug,
            title: context.l10n.text('dbReadiness'),
            accent: nothingConnected ? colors.textMuted : colors.success,
          ),
          const SizedBox(height: DashboardCardStyle.headerGap),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              _ReadinessChip(
                colors: colors,
                icon: LucideIcons.camera,
                label: context.l10n.text('dbCamera'),
                connected: cameraConnected,
                detail: coolerLabel,
              ),
              _ReadinessChip(
                colors: colors,
                icon: LucideIcons.move3d,
                label: context.l10n.text('dbMount'),
                connected: mountConnected,
              ),
              _ReadinessChip(
                colors: colors,
                icon: LucideIcons.crosshair,
                label: context.l10n.text('dbGuider'),
                connected: guiderConnected,
              ),
              _ReadinessChip(
                colors: colors,
                icon: LucideIcons.focus,
                label: context.l10n.text('dbFocuser'),
                connected: focuserConnected,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Divider(height: 1, color: colors.border),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _StorageLine(colors: colors),
          if (nothingConnected) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: context.l10n.text('dbConnectEquipment'),
                icon: LucideIcons.plug,
                variant: ButtonVariant.outline,
                size: ButtonSize.small,
                onPressed: () => context.go('/equipment'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Free-disk line mirroring `storage_card.dart`'s consumption of
/// [captureDirDiskSpaceProvider], including the "no capture path" prompt.
class _StorageLine extends ConsumerWidget {
  final SkotiqColors colors;

  const _StorageLine({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diskAsync = ref.watch(captureDirDiskSpaceProvider);

    return diskAsync.when(
      loading: () => Row(
        children: [
          Icon(LucideIcons.hardDrive, size: 14, color: colors.textMuted),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            context.l10n.text('dbCheckingDisk'),
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
      ),
      error: (e, _) => Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              // Name the missing folder: by far the commonest cause is a
              // capture path that is not there — an unmounted drive, a deleted
              // folder, a path carried over from another machine — and a bare
              // "Disk query failed" is not actionable.
              e is DiskSpaceException &&
                      e.kind == DiskSpaceFailureKind.pathMissing
                  ? context.l10n.text('dbCaptureFolderMissing')
                  : context.l10n.text('dbDiskQueryFailed'),
              style: SkotiqTypography.bodySm.copyWith(color: colors.error),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      data: (info) {
        if (info == null) {
          // imageOutputPath empty — soft prompt, same framing as storage_card.
          return Row(
            children: [
              Icon(LucideIcons.hardDrive, size: 14, color: colors.textMuted),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  context.l10n.text('dbSetCaptureDir'),
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                  maxLines: 2,
                ),
              ),
            ],
          );
        }
        return Row(
          children: [
            Icon(LucideIcons.hardDrive,
                size: 14, color: _freeColor(info.freeBytes)),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(
              context.l10n.text('dbFreeStorage'),
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              '${_gb(info.freeBytes)} GB',
              style: SkotiqTypography.withTabular(
                SkotiqTypography.labelStrongSm.copyWith(
                  color: _freeColor(info.freeBytes),
                ),
              ),
            ),
            Text(
              ' / ${_gb(info.totalBytes)}',
              style: SkotiqTypography.withTabular(
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
              ),
            ),
          ],
        );
      },
    );
  }

  Color _freeColor(int freeBytes) {
    if (freeBytes < 2 * 1024 * 1024 * 1024) return colors.error;
    if (freeBytes < 10 * 1024 * 1024 * 1024) return colors.warning;
    return colors.textPrimary;
  }

  static String _gb(int bytes) {
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb < 10) return gb.toStringAsFixed(2);
    if (gb < 100) return gb.toStringAsFixed(1);
    return gb.toStringAsFixed(0);
  }
}

class _ReadinessChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final bool connected;
  final String? detail;

  const _ReadinessChip({
    required this.colors,
    required this.icon,
    required this.label,
    required this.connected,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final accent = connected ? colors.success : colors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.textMuted),
          const SizedBox(width: 6),
          Text(
            label,
            style: SkotiqTypography.labelStrongSm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(width: 6),
          StatusDot(color: accent, size: 8),
          if (detail != null) ...[
            const SizedBox(width: 6),
            Text(
              detail!,
              style: SkotiqTypography.withTabular(
                SkotiqTypography.labelStrongSm.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
