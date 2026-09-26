import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../theme/nightshade_colors.dart';
import '../theme/nightshade_tokens.dart';
import '../theme/nightshade_typography.dart';
import '../components/nightshade_button.dart';
import '../dialogs/nightshade_dialog.dart';

/// Dialog shown when an update is available.
class UpdateAvailableDialog extends StatelessWidget {
  final String currentVersion;
  final String newVersion;
  final String? releaseNotes;
  final int downloadSizeMb;
  final VoidCallback onUpdate;
  final VoidCallback onSkip;
  final VoidCallback onLater;

  /// When true the build is below the minimum version for automatic updates:
  /// the download/apply path is hidden and the dialog presents manual
  /// reinstall guidance instead of "Update Now".
  final bool requiresManualUpgrade;

  const UpdateAvailableDialog({
    super.key,
    required this.currentVersion,
    required this.newVersion,
    this.releaseNotes,
    required this.downloadSizeMb,
    required this.onUpdate,
    required this.onSkip,
    required this.onLater,
    this.requiresManualUpgrade = false,
  });

  static Future<void> show(
    BuildContext context, {
    required String currentVersion,
    required String newVersion,
    String? releaseNotes,
    required int downloadSizeMb,
    required VoidCallback onUpdate,
    required VoidCallback onSkip,
    required VoidCallback onLater,
    bool requiresManualUpgrade = false,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => UpdateAvailableDialog(
        currentVersion: currentVersion,
        newVersion: newVersion,
        releaseNotes: releaseNotes,
        downloadSizeMb: downloadSizeMb,
        requiresManualUpgrade: requiresManualUpgrade,
        onUpdate: () {
          Navigator.pop(context);
          onUpdate();
        },
        onSkip: () {
          Navigator.pop(context);
          onSkip();
        },
        onLater: () {
          Navigator.pop(context);
          onLater();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.nightshadeColors;

    return NightshadeDialog(
      title: requiresManualUpgrade
          ? 'Manual Update Required'
          : 'Update Available',
      icon: requiresManualUpgrade
          ? LucideIcons.alertTriangle
          : LucideIcons.download,
      width: 520,
      showCloseButton: false,
      actions: [
        NightshadeButton(
          label: 'Skip This Version',
          onPressed: onSkip,
          variant: ButtonVariant.ghost,
          size: ButtonSize.medium,
        ),
        NightshadeButton(
          label: 'Later',
          onPressed: onLater,
          variant: ButtonVariant.outline,
          size: ButtonSize.medium,
        ),
        if (!requiresManualUpgrade)
          NightshadeButton(
            label: 'Update Now',
            icon: LucideIcons.download,
            onPressed: onUpdate,
            variant: ButtonVariant.primary,
            size: ButtonSize.medium,
          ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Version info
          Container(
            padding: NightshadeTokens.paddingMd,
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: NightshadeTokens.borderRadiusMd,
              border: Border.all(color: colors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Current Version',
                        style: NightshadeTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(height: NightshadeTokens.spaceXs),
                      Text(
                        currentVersion,
                        style: NightshadeTypography.bodyLg.copyWith(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  LucideIcons.arrowRight,
                  color: colors.primary,
                  size: NightshadeTokens.iconSm,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'New Version',
                        style: NightshadeTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(height: NightshadeTokens.spaceXs),
                      Text(
                        newVersion,
                        style: NightshadeTypography.bodyLg.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: NightshadeTokens.spaceLg),

          if (requiresManualUpgrade)
            Container(
              padding: NightshadeTokens.paddingMd,
              decoration: BoxDecoration(
                color: colors.warning.withValues(alpha: 0.1),
                borderRadius: NightshadeTokens.borderRadiusMd,
                border: Border.all(
                  color: colors.warning.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    LucideIcons.alertTriangle,
                    color: colors.warning,
                    size: NightshadeTokens.iconSm,
                  ),
                  const SizedBox(width: NightshadeTokens.spaceMd),
                  Expanded(
                    child: Text(
                      'This build is older than the minimum version supported '
                      'by automatic updates. Download the latest full release '
                      'and reinstall Nightshade manually to continue.',
                      style: NightshadeTypography.bodySm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            // Download size
            Row(
              children: [
                Icon(
                  LucideIcons.hardDrive,
                  color: colors.textMuted,
                  size: NightshadeTokens.iconSm,
                ),
                const SizedBox(width: NightshadeTokens.spaceSm),
                Text(
                  'Download size: ~$downloadSizeMb MB',
                  style: NightshadeTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),

            // Release notes
            if (releaseNotes != null) ...[
              const SizedBox(height: NightshadeTokens.spaceLg),
              Text(
                'What\'s New:',
                style: NightshadeTypography.bodyMedium.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: NightshadeTokens.spaceSm),
              Container(
                constraints: const BoxConstraints(maxHeight: 150),
                padding: NightshadeTokens.paddingMd,
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: NightshadeTokens.borderRadiusMd,
                  border: Border.all(color: colors.border),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    releaseNotes!,
                    style: NightshadeTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Dialog shown during update download with progress.
class UpdateDownloadDialog extends StatelessWidget {
  final String version;
  final double progress;
  final int downloadedMb;
  final int totalMb;
  final String status;
  final VoidCallback? onCancel;

  const UpdateDownloadDialog({
    super.key,
    required this.version,
    required this.progress,
    required this.downloadedMb,
    required this.totalMb,
    required this.status,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.nightshadeColors;
    final percent = (progress * 100).toStringAsFixed(0);

    return NightshadeDialog(
      title: 'Downloading Update',
      icon: LucideIcons.downloadCloud,
      width: 440,
      showCloseButton: false,
      actions: [
        if (onCancel != null)
          NightshadeButton(
            label: 'Cancel',
            onPressed: onCancel,
            variant: ButtonVariant.ghost,
            size: ButtonSize.medium,
          ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Version $version',
            style: NightshadeTypography.body.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: NightshadeTokens.spaceLg),

          // Progress bar
          ClipRRect(
            borderRadius: NightshadeTokens.borderRadiusXs,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: colors.border,
              valueColor: AlwaysStoppedAnimation(colors.primary),
            ),
          ),

          const SizedBox(height: NightshadeTokens.spaceMd),

          // Progress details
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                status,
                style: NightshadeTypography.bodySm.copyWith(
                  color: colors.textMuted,
                ),
              ),
              Text(
                '$percent% ($downloadedMb / $totalMb MB)',
                style: NightshadeTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Dialog shown when update is ready to install.
class UpdateReadyDialog extends StatelessWidget {
  final String version;
  final bool isSessionActive;

  /// True where the OS performs the install (Android's package installer)
  /// rather than Nightshade swapping its own files and relaunching. The
  /// wording has to follow: on those platforms the app does not restart
  /// itself, the system hands the user a confirmation screen and replaces
  /// the app once they accept.
  final bool installsViaSystemInstaller;

  final VoidCallback onRestartNow;
  final VoidCallback onRestartLater;

  const UpdateReadyDialog({
    super.key,
    required this.version,
    required this.isSessionActive,
    this.installsViaSystemInstaller = false,
    required this.onRestartNow,
    required this.onRestartLater,
  });

  static Future<void> show(
    BuildContext context, {
    required String version,
    required bool isSessionActive,
    bool installsViaSystemInstaller = false,
    required VoidCallback onRestartNow,
    required VoidCallback onRestartLater,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => UpdateReadyDialog(
        version: version,
        isSessionActive: isSessionActive,
        installsViaSystemInstaller: installsViaSystemInstaller,
        onRestartNow: () {
          Navigator.pop(context);
          onRestartNow();
        },
        onRestartLater: () {
          Navigator.pop(context);
          onRestartLater();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.nightshadeColors;

    return NightshadeDialog(
      title: 'Update Ready',
      icon: LucideIcons.checkCircle,
      width: 460,
      showCloseButton: false,
      actions: [
        NightshadeButton(
          label: installsViaSystemInstaller ? 'Not Now' : 'Restart Later',
          onPressed: onRestartLater,
          variant: ButtonVariant.outline,
          size: ButtonSize.medium,
        ),
        NightshadeButton(
          label: installsViaSystemInstaller
              ? (isSessionActive ? 'Install Anyway' : 'Install Now')
              : (isSessionActive ? 'Restart Anyway' : 'Restart Now'),
          icon: LucideIcons.refreshCw,
          onPressed: onRestartNow,
          variant: isSessionActive
              ? ButtonVariant.outline
              : ButtonVariant.primary,
          size: ButtonSize.medium,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Version $version has been downloaded and is ready to install.',
            style: NightshadeTypography.body.copyWith(
              color: colors.textSecondary,
            ),
          ),
          if (isSessionActive) ...[
            const SizedBox(height: NightshadeTokens.spaceLg),
            Container(
              padding: NightshadeTokens.paddingMd,
              decoration: BoxDecoration(
                color: colors.warning.withValues(alpha: 0.1),
                borderRadius: NightshadeTokens.borderRadiusMd,
                border: Border.all(
                  color: colors.warning.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.alertTriangle,
                    color: colors.warning,
                    size: NightshadeTokens.iconSm,
                  ),
                  const SizedBox(width: NightshadeTokens.spaceMd),
                  Expanded(
                    child: Text(
                      installsViaSystemInstaller
                          ? 'An imaging session is in progress. Installing '
                                'now closes Nightshade and interrupts it.'
                          : 'An imaging session is in progress. It\'s recommended to wait until the session completes before restarting.',
                      style: NightshadeTypography.bodySm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: NightshadeTokens.spaceLg),
          Text(
            installsViaSystemInstaller
                ? 'Android will ask you to confirm, then replace Nightshade. '
                      'Your data stays where it is.'
                : 'Nightshade will restart to complete the installation.',
            style: NightshadeTypography.bodySm.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small notification banner for LAN push updates received.
class UpdateReceivedBanner extends StatelessWidget {
  final String version;
  final String source;
  final VoidCallback onRestart;
  final VoidCallback onDismiss;

  const UpdateReceivedBanner({
    super.key,
    required this.version,
    required this.source,
    required this.onRestart,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.nightshadeColors;

    return Material(
      color: Colors.transparent,
      child: Container(
        margin: NightshadeTokens.paddingLg,
        padding: const EdgeInsets.symmetric(
          horizontal: NightshadeTokens.spaceLg,
          vertical: NightshadeTokens.spaceMd,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: NightshadeTokens.borderRadiusMd,
          border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
          boxShadow: NightshadeTokens.shadowMd,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: NightshadeTokens.paddingSm,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.1),
                borderRadius: NightshadeTokens.borderRadiusMd,
              ),
              child: Icon(
                LucideIcons.download,
                color: colors.primary,
                size: NightshadeTokens.iconSm,
              ),
            ),
            const SizedBox(width: NightshadeTokens.spaceMd),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Update Received',
                    style: NightshadeTypography.bodyMedium.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'Version $version from $source',
                    style: NightshadeTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            NightshadeButton(
              label: 'Later',
              onPressed: onDismiss,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
            const SizedBox(width: NightshadeTokens.spaceSm),
            NightshadeButton(
              label: 'Restart',
              icon: LucideIcons.refreshCw,
              onPressed: onRestart,
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
            ),
          ],
        ),
      ),
    );
  }
}
