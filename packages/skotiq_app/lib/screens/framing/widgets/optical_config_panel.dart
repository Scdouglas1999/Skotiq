import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Panel that displays optical configuration from the active equipment profile.
/// Shows telescope specs, camera specs, FOV, and image scale.
/// Allows switching between profiles directly from the framing screen.
/// Can be dismissed via the close button; state is stored in FramingState.
class OpticalConfigPanel extends ConsumerWidget {
  const OpticalConfigPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);

    // Watch optical config from provider
    final opticalConfig = ref.watch(opticalConfigProvider);
    final activeProfile = ref.watch(activeEquipmentProfileProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final maxWidth = Responsive.previewOverlayMaxWidth(
          viewportWidth,
          maxAbsolute: 260,
        );
        return Container(
          width: double.infinity,
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: SkotiqTokens.borderRadiusInline8,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(SkotiqIcons.aperture, size: 14, color: colors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'OPTICAL CONFIG',
                      style: SkotiqTypography.eyebrow
                          .copyWith(color: colors.textMuted),
                    ),
                  ),
                  SkotiqIconButton(
                    icon: SkotiqIcons.close,
                    tooltip: 'Hide optical config panel',
                    size: IconButtonSize.sm,
                    onPressed: () {
                      ref
                          .read(framingProvider.notifier)
                          .setOpticalConfigPanelVisible(false);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (opticalConfig == null || !_hasValidConfig(opticalConfig))
                _buildMissingConfigState(context, colors, activeProfile)
              else
                _buildConfigDisplay(
                  context,
                  colors,
                  opticalConfig,
                  activeProfile,
                  ref,
                ),
            ],
          ),
        );
      },
    );
  }

  bool _hasValidConfig(OpticalConfig config) {
    return config.focalLength != null && config.focalLength! > 0;
  }

  Widget _buildMissingConfigState(
    BuildContext context,
    SkotiqColors colors,
    EquipmentProfileModel? activeProfile,
  ) {
    return Column(
      children: [
        Icon(
          SkotiqIcons.warning,
          size: 32,
          color: colors.warning,
        ),
        const SizedBox(height: 12),
        Text(
          activeProfile == null
              ? 'No equipment profile'
              : 'No optical configuration',
          style:
              SkotiqTypography.bodyStrong.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 8),
        Text(
          activeProfile == null
              ? 'Create and activate an equipment profile to see your field of view.'
              : 'Set up your telescope and camera to see accurate field of view.',
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        SkotiqButton(
          label: 'Configure in Equipment',
          icon: SkotiqIcons.settings2,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => context.go('/equipment'),
        ),
      ],
    );
  }

  Widget _buildConfigDisplay(
    BuildContext context,
    SkotiqColors colors,
    OpticalConfig config,
    EquipmentProfileModel? profile,
    WidgetRef ref,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Telescope info
        if (config.telescopeName != null) ...[
          Row(
            children: [
              const Text('\u{1F52D}',
                  style: SkotiqTypography.body), // Telescope emoji
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  config.telescopeName!,
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],

        // Optical specs
        Text(
          _formatOpticalSpecs(config),
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),

        const SizedBox(height: 12),

        // Camera info
        if (config.cameraName != null) ...[
          Row(
            children: [
              const Text('\u{1F4F7}',
                  style: SkotiqTypography.body), // Camera emoji
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  config.cameraName!,
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],

        // Sensor specs
        if (config.sensorWidth != null && config.sensorHeight != null)
          Text(
            _formatSensorSpecs(config),
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          ),

        const SizedBox(height: 16),
        Divider(color: colors.border, height: 1),
        const SizedBox(height: 12),

        // FOV and Scale
        _buildMetricRow(
          'FOV',
          config.fovString ?? kReadoutUnknown,
          colors,
        ),
        const SizedBox(height: 8),
        _buildMetricRow(
          'Scale',
          config.scaleString ?? kReadoutUnknown,
          colors,
        ),

        const SizedBox(height: 16),

        // Profile switcher
        _ProfileSwitcher(currentProfile: profile),
      ],
    );
  }

  String _formatOpticalSpecs(OpticalConfig config) {
    final parts = <String>[];
    if (config.focalLength != null) {
      parts.add('${config.focalLength!.toStringAsFixed(0)}mm');
    }
    final fRatio = config.computedFocalRatio;
    if (fRatio != null) {
      parts.add('f/${fRatio.toStringAsFixed(1)}');
    }
    if (config.aperture != null) {
      parts.add('@ ${config.aperture!.toStringAsFixed(0)}mm');
    }
    return parts.join(' ');
  }

  String _formatSensorSpecs(OpticalConfig config) {
    final dims = '${config.sensorWidth} \u00D7 ${config.sensorHeight} px';
    if (config.pixelSize != null) {
      return '$dims (${config.pixelSize!.toStringAsFixed(2)}\u00B5m)';
    }
    return dims;
  }

  Widget _buildMetricRow(String label, String value, SkotiqColors colors) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
        Text(
          value,
          style: SkotiqTypography.readoutSm
              .copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _ProfileSwitcher extends ConsumerWidget {
  final EquipmentProfileModel? currentProfile;

  const _ProfileSwitcher({this.currentProfile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final profilesAsync = ref.watch(allProfilesProvider);

    return profilesAsync.when(
      data: (profiles) {
        if (profiles.isEmpty) {
          return const SizedBox.shrink();
        }

        return PopupMenuButton<int>(
          tooltip: 'Switch equipment profile',
          offset: const Offset(0, 40),
          color: colors.well,
          shape: RoundedRectangleBorder(
            borderRadius: SkotiqTokens.borderRadiusInline8,
            side: BorderSide(color: colors.border),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: colors.border),
              borderRadius: SkotiqTokens.borderRadiusInline8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Text(
                    currentProfile?.name ?? 'Select Profile',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(SkotiqIcons.chevronDown,
                    size: 14, color: colors.textMuted),
              ],
            ),
          ),
          itemBuilder: (context) => profiles.map((profile) {
            final isSelected = profile.id == currentProfile?.id;
            return PopupMenuItem<int>(
              value: profile.id,
              child: Row(
                children: [
                  if (isSelected)
                    Icon(SkotiqIcons.check, size: 14, color: colors.success)
                  else
                    const SizedBox(width: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      profile.name,
                      style: SkotiqTypography.caption.copyWith(
                        color: isSelected
                            ? colors.textPrimary
                            : colors.textSecondary,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                  if (profile.isActive)
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.2),
                        borderRadius: SkotiqTokens.borderRadiusInline4,
                      ),
                      child: Text(
                        'Active',
                        style: SkotiqTypography.caption.copyWith(
                            color: colors.primary, fontWeight: FontWeight.w500),
                      ),
                    ),
                ],
              ),
            );
          }).toList(),
          onSelected: (profileId) async {
            // Single activation authority: the remote-aware notifier updates
            // SQLite and write-throughs the active row into the native executor
            // store (local), or hits the host load endpoint (remote) — a bare
            // DAO write would leave the Rust sequencer on the old profile.
            await ref
                .read(equipmentProfilesProvider.notifier)
                .setActiveProfile(profileId);
          },
        );
      },
      loading: () => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: colors.border),
          borderRadius: SkotiqTokens.borderRadiusInline8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(colors.textMuted),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Loading...',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
      error: (error, _) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: colors.error.withValues(alpha: 0.5)),
          borderRadius: SkotiqTokens.borderRadiusInline8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.alertCircle, size: 12, color: colors.error),
            const SizedBox(width: 8),
            Text(
              'Error loading profiles',
              style: SkotiqTypography.caption.copyWith(color: colors.error),
            ),
          ],
        ),
      ),
    );
  }
}
