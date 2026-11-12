import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../screens/settings/settings_sections.dart';

/// The download button's label, with the disk cost in it.
String skyCatalogDownloadLabel() =>
    'Download catalogs ($kInstalledCatalogApproxSizeMB MB)';

/// What one download adds, and what it costs on disk.
String skyCatalogDownloadContents() =>
    'OpenNGC (about ${formatCatalogCount(kInstalledDsoApproxCount)} '
    'deep-sky objects) and the HYG star catalog download together, about '
    '$kInstalledCatalogApproxSizeMB MB from github.com.';

/// True while either catalog the one download installs is missing.
bool skyCatalogsMissing(CatalogState catalogs) =>
    !catalogs.starCatalogStatus.isInstalled ||
    !catalogs.dsoCatalogStatus.isInstalled;

/// Offers, runs and reports the star and deep-sky catalog download where the
/// user finds out it is missing, instead of a link to Settings > Catalogs.
///
/// Every phase is drawn from [skyCatalogInstallProvider], so a download
/// started here, in first-run setup or in Settings is the same one everywhere.
/// [inline] draws it as a block inside a panel; otherwise it is the centered
/// empty state of a surface that has nothing else to show.
class SkyCatalogDownloadPanel extends ConsumerWidget {
  const SkyCatalogDownloadPanel({
    super.key,
    required this.title,
    required this.body,
    this.settingsLabel = 'Open catalog settings',
    this.showSettingsLink = true,
    this.inline = false,
  });

  /// Shown before a download starts.
  final String title;
  final String body;
  final String settingsLabel;

  /// False where leaving for Settings would abandon a flow (first-run setup).
  final bool showSettingsLink;
  final bool inline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final install = ref.watch(skyCatalogInstallProvider);
    final notifier = ref.read(skyCatalogInstallProvider.notifier);

    final settings = SkotiqButton(
      label: settingsLabel,
      variant: ButtonVariant.ghost,
      size: ButtonSize.small,
      onPressed: () =>
          GoRouter.of(context).goToSettings(SettingsSectionId.catalogs),
    );

    final (IconData icon, String heading, String text, List<Widget> actions) =
        switch (install.phase) {
      SkyCatalogInstallPhase.running => (
          LucideIcons.download,
          'Downloading the sky catalogs',
          install.status,
          [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: notifier.cancel,
            ),
          ],
        ),
      SkyCatalogInstallPhase.failed => (
          SkotiqIcons.warning,
          'The catalogs did not download',
          userFacingError(install.error ?? 'The download stopped.'),
          [
            SkotiqButton(
              icon: SkotiqIcons.refresh,
              label: 'Try again',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: notifier.start,
            ),
            if (showSettingsLink) settings,
          ],
        ),
      SkyCatalogInstallPhase.done => (
          LucideIcons.checkCircle2,
          'Sky catalogs installed',
          'The planner, planetarium and search now use them.',
          const <Widget>[],
        ),
      SkyCatalogInstallPhase.idle => (
          LucideIcons.download,
          title,
          body,
          [
            SkotiqButton(
              icon: SkotiqIcons.download,
              label: skyCatalogDownloadLabel(),
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
              onPressed: notifier.start,
            ),
            if (showSettingsLink) settings,
          ],
        ),
    };

    final progress = install.isRunning
        ? SkotiqProgressBar(value: install.progress)
        : null;
    final buttons = actions.isEmpty
        ? null
        : Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            alignment: inline ? WrapAlignment.start : WrapAlignment.center,
            children: actions,
          );

    if (!inline) {
      return EmptyState(
        icon: icon,
        title: heading,
        body: text,
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress != null) ...[
              SizedBox(width: EmptyState.maxWidth, child: progress),
              const SizedBox(height: SkotiqTokens.spaceMd),
            ],
            if (buttons != null) buttons,
          ],
        ),
      );
    }

    final colors = SkotiqColors.of(context);
    final failed = install.phase == SkyCatalogInstallPhase.failed;
    return Container(
      decoration: SkotiqDecorations.well(colors),
      padding: SkotiqTokens.paddingMd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: SkotiqTokens.iconMd,
                color: failed ? colors.warning : colors.textMuted,
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Text(
                  heading,
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            text,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            progress,
          ],
          if (buttons != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            buttons,
          ],
        ],
      ),
    );
  }
}
