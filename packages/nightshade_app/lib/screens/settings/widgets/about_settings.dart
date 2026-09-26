import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_ui/nightshade_ui.dart';
import 'package:nightshade_updater/nightshade_updater.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../utils/snackbar_helper.dart';
import 'settings_widgets.dart';

/// Canonical public home used by both mobile and desktop About layouts.
const String kNightshadeRepositoryUrl =
    'https://github.com/Scdouglas1999/Nightshade';

/// One row of the About page's link strip.
///
/// [compactLabel] is what the phone layout shows, where the buttons sit in a
/// Wrap and a long label pushes the third button onto its own line.
class AboutLink {
  final IconData icon;
  final String label;
  final String compactLabel;
  final String url;

  const AboutLink({
    required this.icon,
    required this.label,
    required this.compactLabel,
    required this.url,
  });
}

/// WHY only these three: a shipped About page must not offer a destination we
/// cannot stand behind. The project has no community chat server, so there is
/// no Discord button — an invite that lands the user in a stranger's server is
/// worse than no button at all. Documentation lives in the repository (the
/// README links `docs/index.md`); there is no docs site to point at.
const List<AboutLink> kAboutLinks = [
  AboutLink(
    icon: LucideIcons.github,
    label: 'GitHub',
    compactLabel: 'GitHub',
    url: kNightshadeRepositoryUrl,
  ),
  AboutLink(
    icon: LucideIcons.bookOpen,
    label: 'Documentation',
    compactLabel: 'Docs',
    url: '$kNightshadeRepositoryUrl/blob/main/docs/index.md',
  ),
  AboutLink(
    icon: LucideIcons.bug,
    label: 'Report an Issue',
    compactLabel: 'Issues',
    url: '$kNightshadeRepositoryUrl/issues',
  ),
];

/// The licence this build ships under, verbatim from the repository's LICENSE
/// file. Settings search sends both `license` and `credits` to About, so the
/// page has to actually carry them.
const String kNightshadeLicenseName =
    'Nightshade Source-Available License v1.2';
const String kNightshadeCopyright = 'Copyright (c) 2025 Sean Douglas';
const String kNightshadeLicenseUrl =
    '$kNightshadeRepositoryUrl/blob/main/LICENSE';

/// Opens an external URL. Injected so a widget test can assert which address a
/// button actually hands to the platform rather than only that it was tapped.
typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);

final aboutLinkLauncherProvider = Provider<ExternalUrlLauncher>(
  (ref) => (uri) async => await canLaunchUrl(uri) && await launchUrl(uri),
);

class AboutSettings extends ConsumerWidget {
  final bool isMobile;

  const AboutSettings({super.key, this.isMobile = false});

  Future<void> _launchUrl(
    BuildContext context,
    WidgetRef ref,
    String url,
  ) async {
    final uri = Uri.parse(url);
    var launched = false;
    try {
      launched = await ref.read(aboutLinkLauncherProvider)(uri);
    } catch (_) {
      launched = false;
    }
    if (!launched && context.mounted) {
      context.showErrorSnackBar('Could not open $url');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = NightshadeColors.of(context);
    final appVersion = ref.watch(appVersionProvider);
    final logoSize = isMobile ? 64.0 : 80.0;
    final logoIconSize = isMobile ? 32.0 : 40.0;

    return SettingsPage(
      title: 'About',
      description: 'Application information',
      isMobile: isMobile,
      hideHeader: isMobile,
      children: [
        Center(
          child: Column(
            children: [
              Container(
                width: logoSize,
                height: logoSize,
                decoration:
                    NightshadeDecorations.chip(colors, tone: colors.primary),
                child: Icon(
                  LucideIcons.sparkles,
                  size: logoIconSize,
                  color: colors.primary,
                ),
              ),
              SizedBox(height: isMobile ? 16 : 20),
              Text(
                'Nightshade',
                style: NightshadeTypography.pageTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Version ${appVersion.version} (build ${appVersion.buildNumber})',
                style: NightshadeTypography.body.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              SizedBox(height: isMobile ? 16 : 20),
              Text(
                'Advanced astrophotography suite',
                style: NightshadeTypography.bodySm.copyWith(
                  color: colors.textMuted,
                ),
              ),
              SizedBox(height: isMobile ? 24 : 32),
              isMobile
                  ? Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final link in kAboutLinks)
                          SettingsLinkButton(
                            icon: link.icon,
                            label: link.compactLabel,
                            onTap: () => _launchUrl(context, ref, link.url),
                            compact: true,
                          ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < kAboutLinks.length; i++) ...[
                          if (i > 0) const SizedBox(width: 12),
                          SettingsLinkButton(
                            icon: kAboutLinks[i].icon,
                            label: kAboutLinks[i].label,
                            onTap: () =>
                                _launchUrl(context, ref, kAboutLinks[i].url),
                          ),
                        ],
                      ],
                    ),
              const SizedBox(height: 32),
              _SoftwareUpdateCard(isMobile: isMobile),
              const SizedBox(height: 32),
              _LicenseCard(
                isMobile: isMobile,
                onOpenUrl: (url) => _launchUrl(context, ref, url),
              ),
              const SizedBox(height: 32),
              const _SystemInformationCard(),
            ],
          ),
        ),
      ],
    );
  }
}

/// One labelled fact in the System Information card.
class SupportFact {
  const SupportFact(this.label, this.value);

  final String label;
  final String value;
}

/// What "System Information" reports.
///
/// A support conversation opens by asking for the build number, which host the
/// app is driving and what schema its data is on — none of which Platform / OS
/// Version / Dart Version answer — so those are gathered here and the whole
/// block is copyable in one action.
///
/// Deliberately synchronous: About must render its facts on the first frame,
/// never behind a spinner. The one fact that cannot be resolved synchronously
/// (the data folder) lives in [nightshadeDataFolderProvider] and is appended
/// when it arrives.
final systemInformationProvider = Provider<List<SupportFact>>((ref) {
  final facts = <SupportFact>[];

  try {
    final version = ref.watch(appVersionProvider);
    facts.add(
      SupportFact(
        'Nightshade',
        '${version.version} (build ${version.buildNumber})',
      ),
    );
  } catch (_) {
    // appVersionProvider throws when nothing overrode it (its documented
    // contract). The rest of the block is still worth reporting.
  }

  facts
    ..add(SupportFact('Platform', Platform.operatingSystem))
    ..add(SupportFact('OS version', Platform.operatingSystemVersion))
    ..add(SupportFact('Dart', Platform.version.split(' ').first));

  final backend = ref.watch(backendProvider);
  facts.add(
    SupportFact(
      'Connected to',
      backend is NetworkBackend
          ? 'imaging host ${backend.serverHost}'
          : 'this computer',
    ),
  );

  try {
    facts.add(
      SupportFact(
        'Database schema',
        '${ref.watch(databaseProvider).schemaVersion}',
      ),
    );
  } catch (_) {
    // No local database in this process (or none configured in a test bench).
  }

  return facts;
});

/// Where this process keeps its writable data, or null while unresolved.
///
/// Its own provider because `path_provider` is a platform channel: awaiting it
/// inside [systemInformationProvider] would put the whole card behind a
/// pending future.
final nightshadeDataFolderProvider = FutureProvider<String?>((ref) async {
  try {
    return (await resolveNightshadeDataDirectory()).path;
  } catch (_) {
    // path_provider can fail on an unusual OS configuration; the rest of the
    // block is still worth showing.
    return null;
  }
});

/// The block a bug report starts with, and a one-press way to hand it over.
class _SystemInformationCard extends ConsumerWidget {
  const _SystemInformationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = NightshadeColors.of(context);
    final dataFolder = ref.watch(nightshadeDataFolderProvider).valueOrNull;
    final facts = [
      ...ref.watch(systemInformationProvider),
      if (dataFolder != null) SupportFact('Data folder', dataFolder),
    ];

    return NightshadePanel(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'System information',
                  style: NightshadeTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              NightshadeButton(
                label: 'Copy',
                icon: LucideIcons.clipboard,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(
                      text:
                          facts.map((f) => '${f.label}: ${f.value}').join('\n'),
                    ),
                  );
                  if (context.mounted) {
                    context.showSuccessSnackBar('System information copied');
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final fact in facts)
            SettingsInfoRow(label: fact.label, value: fact.value),
        ],
      ),
    );
  }
}

/// The licence Nightshade ships under, plus the open-source credits.
///
/// Settings search has always routed `license` and `credits` to About, and
/// About carried neither: the page named a version, a tagline and three links
/// and stopped. Searching for a term that lands on exactly one destination
/// which then does not have it is the search lying about what the app knows.
class _LicenseCard extends ConsumerWidget {
  final bool isMobile;
  final void Function(String url) onOpenUrl;

  const _LicenseCard({required this.isMobile, required this.onOpenUrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = NightshadeColors.of(context);
    final appVersion = ref.watch(appVersionProvider);

    return NightshadePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'License',
            style: NightshadeTypography.bodyStrong
                .copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 12),
          Text(
            '$kNightshadeLicenseName\n$kNightshadeCopyright',
            style: NightshadeTypography.caption.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              NightshadeButton(
                label: 'Read the license',
                icon: LucideIcons.scrollText,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () => onOpenUrl(kNightshadeLicenseUrl),
              ),
              NightshadeButton(
                label: 'Open-source licenses',
                icon: LucideIcons.package,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                // Flutter's own page, fed by LicenseRegistry, so the credits
                // list is the set of packages actually linked into this build
                // rather than a hand-maintained list that would drift.
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'Nightshade',
                  applicationVersion:
                      'Version ${appVersion.version} (build ${appVersion.buildNumber})',
                  applicationLegalese:
                      '$kNightshadeCopyright\n$kNightshadeLicenseName',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Manual "is there a newer Nightshade?" check, and the way in to installing
/// one.
///
/// This is the only local update surface Settings has: searching it for
/// "update" otherwise returns About and the appliance OTA page, which is about
/// a REMOTE rig and renders a single sentence off-network.
///
/// It used to ask the releases API directly and could only report, because
/// the in-app updater had no source configured and so could never answer.
/// Shipped builds now read the project's GitHub releases through that updater,
/// so this drives the real thing: a check here can lead to an install instead
/// of to a browser tab. Finding an update hands off to the standard update
/// dialog, which owns download, verification and apply — including the
/// hardware gate that refuses to swap the binary mid-exposure.
class _SoftwareUpdateCard extends ConsumerStatefulWidget {
  final bool isMobile;

  const _SoftwareUpdateCard({required this.isMobile});

  @override
  ConsumerState<_SoftwareUpdateCard> createState() =>
      _SoftwareUpdateCardState();
}

class _SoftwareUpdateCardState extends ConsumerState<_SoftwareUpdateCard> {
  bool _checking = false;

  /// Run an unthrottled check through the real updater.
  ///
  /// Startup uses the throttled path; a button labelled "Check for updates"
  /// has to actually check, or pressing it after a release lands would sit
  /// there reporting the same stale answer for hours.
  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await ref.read(updateProvider.notifier).checkForUpdates();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// What the check found, in the operator's terms.
  ///
  /// Never claims newer-or-older on its own: the version comparison lives in
  /// the manifest gating, and this only renders the conclusion it reached.
  String _statusLine(UpdateState state) {
    if (_checking || state.status == UpdateStatus.checking) {
      return 'Checking for updates…';
    }

    switch (state.status) {
      case UpdateStatus.checking:
        // Unreachable — the guard above takes this — but the switch stays
        // exhaustive so a new status cannot be added without deciding what
        // this card says about it.
        return 'Checking for updates…';
      case UpdateStatus.error:
        return 'Could not check for updates: '
            '${state.errorMessage ?? "unknown error"}';
      case UpdateStatus.available:
        final version = state.availableUpdate?.version ?? 'A new version';
        if (state.requiresManualUpgrade) {
          return 'Nightshade $version is available, but this build is too old '
              'to update in place. Download the full release and reinstall.';
        }
        return 'Nightshade $version is available.';
      case UpdateStatus.downloading:
        return 'Downloading '
            '${(state.downloadProgress * 100).toStringAsFixed(0)}%…';
      case UpdateStatus.verifying:
        return 'Verifying the download…';
      case UpdateStatus.staged:
        final version = state.availableUpdate?.version ?? 'An update';
        // Staged with a message: an install attempt was refused for a reason
        // the operator can fix (Android's install permission), and the
        // download is still ready once they have.
        final blocked = state.errorMessage;
        if (blocked != null && blocked.isNotEmpty) {
          return '$version is downloaded and ready to install. $blocked';
        }
        return '$version is downloaded and ready to install.';
      case UpdateStatus.applying:
        return 'Installing…';
      case UpdateStatus.upToDate:
        // A newer release that ships nothing for this platform is not the
        // same as being current, and must not be reported as it.
        final unavailable = state.unavailableReason;
        if (unavailable != null && unavailable.isNotEmpty) {
          return '$unavailable You are running ${state.currentVersion}.';
        }
        if (state.skippedVersion != null) {
          return 'You are running ${state.currentVersion}. '
              'Version ${state.skippedVersion} was skipped.';
        }
        return 'You are running the latest release '
            '(${state.currentVersion}).';
      case UpdateStatus.idle:
        if (!state.sourceConfigured) {
          return 'No update source is configured, so this build does not '
              'check for updates.';
        }
        // Reached when no check has completed yet — either the throttled
        // startup check has not run, or this platform does not run one at
        // all. Claiming a background check here would be false on the
        // second, so this says only what is certainly true.
        return 'No update check has run yet. '
            'Check now to look for a new version.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = NightshadeColors.of(context);
    final state = ref.watch(updateProvider);

    final isError = state.status == UpdateStatus.error;
    final busy =
        _checking || state.isBusy || state.status == UpdateStatus.checking;

    // An offered update that this build may install in place. A build below
    // the OTA minimum version is offered, but only as a manual reinstall.
    final canInstall =
        state.status == UpdateStatus.available && !state.requiresManualUpgrade;
    final isStaged = state.status == UpdateStatus.staged;
    final releasePageUrl = state.releasePageUrl;

    return NightshadePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Software update',
            style: NightshadeTypography.bodyStrong
                .copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 12),
          Text(
            _statusLine(state),
            style: NightshadeTypography.caption.copyWith(
              color: isError ? colors.error : colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              NightshadeButton(
                label: 'Check for updates',
                icon: LucideIcons.refreshCw,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                isLoading: busy,
                onPressed: busy ? null : _check,
              ),
              if (canInstall)
                NightshadeButton(
                  label: 'Download and install',
                  icon: LucideIcons.download,
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                  onPressed: () =>
                      ref.read(updateProvider.notifier).downloadUpdate(),
                ),
              if (isStaged)
                NightshadeButton(
                  label: 'Install and restart',
                  icon: LucideIcons.refreshCw,
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                  onPressed: () =>
                      ref.read(updateProvider.notifier).applyUpdate(),
                ),
              if (releasePageUrl != null && releasePageUrl.isNotEmpty)
                NightshadeButton(
                  label: 'Release notes',
                  icon: LucideIcons.externalLink,
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: () => _openLink(releasePageUrl),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    var launched = false;
    try {
      launched = await ref.read(aboutLinkLauncherProvider)(uri);
    } catch (_) {
      launched = false;
    }
    if (!launched && mounted) {
      context.showErrorSnackBar('Could not open $url');
    }
  }
}
