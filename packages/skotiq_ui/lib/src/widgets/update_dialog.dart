import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../components/skotiq_button.dart';
import '../dialogs/skotiq_dialog.dart';

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
    final colors = context.skotiqColors;

    return SkotiqDialog(
      title: requiresManualUpgrade
          ? 'Manual Update Required'
          : 'Update Available',
      icon: requiresManualUpgrade
          ? LucideIcons.alertTriangle
          : LucideIcons.download,
      width: 520,
      showCloseButton: false,
      actions: [
        SkotiqButton(
          label: 'Skip This Version',
          onPressed: onSkip,
          variant: ButtonVariant.ghost,
          size: ButtonSize.medium,
        ),
        SkotiqButton(
          label: 'Later',
          onPressed: onLater,
          variant: ButtonVariant.outline,
          size: ButtonSize.medium,
        ),
        if (!requiresManualUpgrade)
          SkotiqButton(
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
            padding: SkotiqTokens.paddingMd,
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: SkotiqTokens.borderRadiusMd,
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
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(height: SkotiqTokens.spaceXs),
                      Text(
                        currentVersion,
                        style: SkotiqTypography.bodyLg.copyWith(
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
                  size: SkotiqTokens.iconSm,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'New Version',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(height: SkotiqTokens.spaceXs),
                      Text(
                        newVersion,
                        style: SkotiqTypography.bodyLg.copyWith(
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

          const SizedBox(height: SkotiqTokens.spaceLg),

          if (requiresManualUpgrade)
            Container(
              padding: SkotiqTokens.paddingMd,
              decoration: BoxDecoration(
                color: colors.warning.withValues(alpha: 0.1),
                borderRadius: SkotiqTokens.borderRadiusMd,
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
                    size: SkotiqTokens.iconSm,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    child: Text(
                      'This build is older than the minimum version supported '
                      'by automatic updates. Download the latest full release '
                      'and reinstall Skotiq manually to continue.',
                      style: SkotiqTypography.bodySm.copyWith(
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
                  size: SkotiqTokens.iconSm,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(
                  'Download size: ~$downloadSizeMb MB',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),

            // Release notes
            if (releaseNotes != null) ...[
              const SizedBox(height: SkotiqTokens.spaceLg),
              Text(
                'What\'s New:',
                style: SkotiqTypography.bodyMedium.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              Container(
                constraints: const BoxConstraints(maxHeight: 150),
                padding: SkotiqTokens.paddingMd,
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: SkotiqTokens.borderRadiusMd,
                  border: Border.all(color: colors.border),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    releaseNotes!,
                    style: SkotiqTypography.bodySm.copyWith(
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
    final colors = context.skotiqColors;
    final percent = (progress * 100).toStringAsFixed(0);

    return SkotiqDialog(
      title: 'Downloading Update',
      icon: LucideIcons.downloadCloud,
      width: 440,
      showCloseButton: false,
      actions: [
        if (onCancel != null)
          SkotiqButton(
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
            style: SkotiqTypography.body.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),

          // Progress bar
          ClipRRect(
            borderRadius: SkotiqTokens.borderRadiusXs,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: colors.border,
              valueColor: AlwaysStoppedAnimation(colors.primary),
            ),
          ),

          const SizedBox(height: SkotiqTokens.spaceMd),

          // Progress details
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                status,
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textMuted,
                ),
              ),
              Text(
                '$percent% ($downloadedMb / $totalMb MB)',
                style: SkotiqTypography.bodySm.copyWith(
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
  /// rather than Skotiq swapping its own files and relaunching. The
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
    final colors = context.skotiqColors;

    return SkotiqDialog(
      title: 'Update Ready',
      icon: LucideIcons.checkCircle,
      width: 460,
      showCloseButton: false,
      actions: [
        SkotiqButton(
          label: installsViaSystemInstaller ? 'Not Now' : 'Restart Later',
          onPressed: onRestartLater,
          variant: ButtonVariant.outline,
          size: ButtonSize.medium,
        ),
        SkotiqButton(
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
            style: SkotiqTypography.body.copyWith(
              color: colors.textSecondary,
            ),
          ),
          if (isSessionActive) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            Container(
              padding: SkotiqTokens.paddingMd,
              decoration: BoxDecoration(
                color: colors.warning.withValues(alpha: 0.1),
                borderRadius: SkotiqTokens.borderRadiusMd,
                border: Border.all(
                  color: colors.warning.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.alertTriangle,
                    color: colors.warning,
                    size: SkotiqTokens.iconSm,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    child: Text(
                      installsViaSystemInstaller
                          ? 'An imaging session is in progress. Installing '
                                'now closes Skotiq and interrupts it.'
                          : 'An imaging session is in progress. It\'s recommended to wait until the session completes before restarting.',
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text(
            installsViaSystemInstaller
                ? 'Android will ask you to confirm, then replace Skotiq. '
                      'Your data stays where it is.'
                : 'Skotiq will restart to complete the installation.',
            style: SkotiqTypography.bodySm.copyWith(
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
    final colors = context.skotiqColors;

    return Material(
      color: Colors.transparent,
      child: Container(
        margin: SkotiqTokens.paddingLg,
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceLg,
          vertical: SkotiqTokens.spaceMd,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: SkotiqTokens.borderRadiusMd,
          border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
          boxShadow: SkotiqTokens.shadowMd,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: SkotiqTokens.paddingSm,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.1),
                borderRadius: SkotiqTokens.borderRadiusMd,
              ),
              child: Icon(
                LucideIcons.download,
                color: colors.primary,
                size: SkotiqTokens.iconSm,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Update Received',
                    style: SkotiqTypography.bodyMedium.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'Version $version from $source',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            SkotiqButton(
              label: 'Later',
              onPressed: onDismiss,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            SkotiqButton(
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
