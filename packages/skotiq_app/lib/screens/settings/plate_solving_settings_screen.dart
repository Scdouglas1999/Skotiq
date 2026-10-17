import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../utils/snackbar_helper.dart';
import '../../widgets/remote_host_path_dialog.dart';
import 'widgets/plate_solve_parameters_section.dart';
import 'widgets/settings_widgets.dart';
import 'widgets/solver_detection_card.dart';

enum PlateSolverPathKind {
  astapExecutable,
  astapCatalogDirectory,
  astrometryExecutable,
}

typedef PlateSolverPathPicker = Future<String?> Function({
  required BuildContext context,
  required PlateSolverPathKind kind,
  required bool isRemote,
  required String currentPath,
});

Future<String?> _pickPlateSolverPath({
  required BuildContext context,
  required PlateSolverPathKind kind,
  required bool isRemote,
  required String currentPath,
}) async {
  if (isRemote) {
    return switch (kind) {
      PlateSolverPathKind.astapExecutable => RemoteHostPathDialog.show(
          context,
          title: 'ASTAP executable on imaging host',
          initialPath: currentPath,
          hintText: r'C:\Program Files\astap\astap.exe or /usr/bin/astap',
          submitLabel: 'Use host path',
          clearLabel: 'Use auto-detect',
        ),
      PlateSolverPathKind.astapCatalogDirectory => RemoteHostPathDialog.show(
          context,
          title: 'ASTAP catalog directory on imaging host',
          initialPath: currentPath,
          hintText: r'C:\Program Files\astap or /opt/astap',
          submitLabel: 'Use host path',
          clearLabel: 'Use auto-detect',
        ),
      PlateSolverPathKind.astrometryExecutable => RemoteHostPathDialog.show(
          context,
          title: 'solve-field executable on imaging host',
          initialPath: currentPath,
          hintText: '/usr/bin/solve-field',
          submitLabel: 'Use host path',
          clearLabel: 'Use auto-detect',
        ),
    };
  }

  if (kind == PlateSolverPathKind.astapCatalogDirectory) {
    return getDirectoryPath(confirmButtonText: 'Use this catalog folder');
  }

  final label = kind == PlateSolverPathKind.astapExecutable
      ? 'ASTAP executable'
      : 'solve-field';
  final file = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: label,
        extensions: Platform.isWindows ? const ['exe'] : null,
      ),
    ],
    confirmButtonText: kind == PlateSolverPathKind.astapExecutable
        ? 'Use this ASTAP'
        : 'Use this solve-field',
  );
  return file?.path;
}

final plateSolverPathPickerProvider =
    Provider<PlateSolverPathPicker>((ref) => _pickPlateSolverPath);

/// Dedicated full-screen Plate Solving route.
class PlateSolvingSettingsScreen extends ConsumerWidget {
  const PlateSolvingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Plate Solving'),
        iconTheme: IconThemeData(color: colors.textPrimary),
        titleTextStyle: SkotiqTypography.pageTitle.copyWith(
          color: colors.textPrimary,
        ),
      ),
      body: const PlateSolvingSettings(),
    );
  }
}

/// Full plate-solving setup UI shared by the Settings catalog and the
/// dedicated `/settings/plate-solving` route.
class PlateSolvingSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const PlateSolvingSettings({super.key, this.isMobile = false});

  @override
  ConsumerState<PlateSolvingSettings> createState() =>
      _PlateSolvingSettingsState();
}

class _PlateSolvingSettingsState extends ConsumerState<PlateSolvingSettings> {
  bool _isChoosingPath = false;
  int _pathChoiceGeneration = 0;

  Future<void> _browseAstapExecutable(PlateSolverPreference current) async {
    await _choosePath(
      kind: PlateSolverPathKind.astapExecutable,
      currentPath: current.astapPath,
      update: (path) => current.copyWith(astapPath: path),
    );
  }

  Future<void> _browseAstapCatalogDirectory(
    PlateSolverPreference current,
  ) async {
    await _choosePath(
      kind: PlateSolverPathKind.astapCatalogDirectory,
      currentPath: current.catalogPath,
      update: (path) => current.copyWith(catalogPath: path),
    );
  }

  Future<void> _browseAstrometryExecutable(
    PlateSolverPreference current,
  ) async {
    await _choosePath(
      kind: PlateSolverPathKind.astrometryExecutable,
      currentPath: current.astrometryPath,
      update: (path) => current.copyWith(astrometryPath: path),
    );
  }

  Future<void> _choosePath({
    required PlateSolverPathKind kind,
    required String currentPath,
    required PlateSolverPreference Function(String path) update,
  }) async {
    if (_isChoosingPath) return;
    final generation = ++_pathChoiceGeneration;
    final authority = ref.read(backendProvider);
    setState(() => _isChoosingPath = true);

    try {
      final path = await ref.read(plateSolverPathPickerProvider)(
        context: context,
        kind: kind,
        isRemote: authority is NetworkBackend,
        currentPath: currentPath,
      );
      if (path == null || !_isCurrentPathChoice(generation, authority)) return;

      await _savePreference(
        update(path),
        expectedAuthority: authority,
      );
    } catch (error) {
      if (mounted && _isCurrentPathChoice(generation, authority)) {
        context.showErrorSnackBar(
          'Could not choose a plate-solver path: $error',
        );
      }
    } finally {
      if (_isCurrentPathChoice(generation, authority)) {
        setState(() => _isChoosingPath = false);
      }
    }
  }

  bool _isCurrentPathChoice(
    int generation,
    SkotiqBackend authority,
  ) {
    return mounted &&
        generation == _pathChoiceGeneration &&
        identical(ref.read(backendProvider), authority);
  }

  Future<void> _savePreference(
    PlateSolverPreference next, {
    Object? expectedAuthority,
  }) async {
    final authority = expectedAuthority ?? ref.read(backendProvider);
    if (!identical(ref.read(backendProvider), authority)) {
      if (mounted) {
        context.showWarningSnackBar(
          'The imaging host changed while choosing that path. Choose it '
          'again for the current host.',
        );
      }
      return;
    }
    final notifier = ref.read(plateSolverSettingsNotifierProvider.notifier);
    try {
      final ok = await notifier.updatePreference(next);
      if (!mounted) return;
      if (!identical(ref.read(backendProvider), authority)) {
        context.showWarningSnackBar(
          'The imaging host changed while saving. Verify the path on the '
          'current host.',
        );
        return;
      }
      if (ok) {
        context.showSuccessSnackBar('Plate-solver settings saved.');
      } else {
        context.showErrorSnackBar('Another save is already in flight. Wait, '
            'then try again.');
      }
    } catch (e) {
      if (!mounted || !identical(ref.read(backendProvider), authority)) return;
      context.showErrorSnackBar('Failed to save plate-solver settings: $e');
    }
  }

  Future<void> _rescan() async {
    final authority = ref.read(backendProvider);
    final notifier = ref.read(plateSolverSettingsNotifierProvider.notifier);
    try {
      final started = await notifier.rescan();
      if (!started ||
          !mounted ||
          !identical(ref.read(backendProvider), authority)) {
        return;
      }
      context.showSuccessSnackBar('Re-scanned plate-solver paths.');
    } catch (e) {
      if (!mounted || !identical(ref.read(backendProvider), authority)) return;
      context.showErrorSnackBar('Re-scan failed: $e');
    }
  }

  Future<void> _verifyAstap(String executablePath) async {
    final notifier = ref.read(plateSolverSettingsNotifierProvider.notifier);
    await notifier.verifyAstap(executablePath);
  }

  Future<void> _verifyAstrometry(String executablePath) async {
    final notifier = ref.read(plateSolverSettingsNotifierProvider.notifier);
    await notifier.verifyAstrometry(executablePath);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (!_isChoosingPath || previous == null || identical(previous, next)) {
        return;
      }
      _pathChoiceGeneration++;
      setState(() => _isChoosingPath = false);
    });

    final colors = SkotiqColors.of(context);
    final authority = ref.watch(backendProvider);
    final detectionAsync = ref.watch(plateSolverDetectionProvider);
    final prefAsync = ref.watch(plateSolverPreferenceProvider);
    final uiState = ref.watch(plateSolverSettingsNotifierProvider);

    return detectionAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.alertCircle, color: colors.error, size: 32),
              const SizedBox(height: 12),
              Text(
                'Plate-solver detection failed. Check that your solver is '
                'installed, then retry.',
                style: SkotiqTypography.body.copyWith(
                  color: colors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              SkotiqButton(
                label: 'Retry',
                onPressed: uiState.rescanning ? null : _rescan,
                icon: LucideIcons.refreshCw,
                isLoading: uiState.rescanning,
              ),
            ],
          ),
        ),
      ),
      data: (detection) => prefAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load plate-solver preferences.',
              style: SkotiqTypography.body.copyWith(
                color: colors.error,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (pref) => _buildBody(
          detection: detection,
          preference: pref,
          uiState: uiState,
          authority: authority,
        ),
      ),
    );
  }

  Widget _buildBody({
    required PlateSolverDetection detection,
    required PlateSolverPreference preference,
    required PlateSolverSettingsState uiState,
    required SkotiqBackend authority,
  }) {
    return SettingsPage(
      title: 'Plate solving',
      description:
          'Configure ASTAP / Astrometry.net for centering, framing, and '
          'polar alignment.',
      isMobile: widget.isMobile,
      children: [
        SolverDetectionCard(
          detection: detection,
          choice: preference.choice,
          astapVerifyInfo: uiState.astapVerifyInfo,
          astapVerifyError: uiState.astapVerifyError,
          astrometryVerifyInfo: uiState.astrometryVerifyInfo,
          astrometryVerifyError: uiState.astrometryVerifyError,
        ),
        if (!detection.supports(preference.choice) &&
            preference.choice != PlateSolverChoice.astrometry &&
            detection.astapPath != null &&
            !detection.astapReady) ...[
          const SizedBox(height: 12),
          _CatalogMissingHint(
            preference: preference,
            isBrowsing: _isChoosingPath,
            onBrowseCatalog: _isChoosingPath
                ? null
                : () => _browseAstapCatalogDirectory(preference),
          ),
        ] else if (!detection.hasAnySolver) ...[
          const SizedBox(height: 16),
          _NoSolverQuickStart(
            onRescan: uiState.rescanning ? null : _rescan,
            isRescanning: uiState.rescanning,
          ),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: SkotiqButton(
            label: uiState.rescanning ? 'Re-scanning…' : 'Re-scan',
            icon: LucideIcons.refreshCw,
            variant: ButtonVariant.secondary,
            isLoading: uiState.rescanning,
            onPressed: uiState.rescanning ? null : _rescan,
          ),
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: 'ASTAP',
          children: [
            SettingRow(
              icon: LucideIcons.fileCode,
              title: 'ASTAP executable',
              subtitle: preference.astapPath.isEmpty
                  ? (detection.astapPath ?? 'Auto-detect — not found')
                  : preference.astapPath,
              trailing: SettingsPathInput(
                key: const ValueKey('plate_solver_astap_path'),
                path: preference.astapPath,
                onBrowse: () => _browseAstapExecutable(preference),
                authorityKey: authority,
              ),
            ),
            SettingRow(
              icon: LucideIcons.folder,
              title: 'ASTAP catalog directory',
              subtitle: preference.catalogPath.isEmpty
                  ? (detection.catalogPath ?? 'Auto-detect — not found')
                  : preference.catalogPath,
              trailing: SettingsPathInput(
                key: const ValueKey('plate_solver_catalog_path'),
                path: preference.catalogPath,
                onBrowse: () => _browseAstapCatalogDirectory(preference),
                authorityKey: authority,
              ),
            ),
            SettingRow(
              icon: LucideIcons.shieldCheck,
              title: 'Verify ASTAP',
              subtitle: _verifyAstapSubtitle(
                  detection: detection,
                  preference: preference,
                  uiState: uiState),
              trailing: SkotiqButton(
                label: uiState.verifying ? 'Verifying…' : 'Verify',
                icon: LucideIcons.play,
                variant: ButtonVariant.secondary,
                isLoading: uiState.verifying,
                onPressed: _resolveAstapTarget(detection, preference) == null
                    ? null
                    : () => _verifyAstap(
                        _resolveAstapTarget(detection, preference)!),
              ),
              isLast: true,
            ),
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: 'Astrometry.net',
          children: [
            SettingRow(
              icon: LucideIcons.fileCode,
              title: 'solve-field executable',
              subtitle: preference.astrometryPath.isEmpty
                  ? (detection.astrometryPath ?? 'Auto-detect — not found')
                  : preference.astrometryPath,
              trailing: SettingsPathInput(
                key: const ValueKey('plate_solver_astrometry_path'),
                path: preference.astrometryPath,
                onBrowse: () => _browseAstrometryExecutable(preference),
                authorityKey: authority,
              ),
            ),
            SettingRow(
              icon: LucideIcons.shieldCheck,
              title: 'Verify Astrometry.net',
              subtitle: _verifyAstrometrySubtitle(
                  detection: detection,
                  preference: preference,
                  uiState: uiState),
              trailing: SkotiqButton(
                label: uiState.verifying ? 'Verifying…' : 'Verify',
                icon: LucideIcons.play,
                variant: ButtonVariant.secondary,
                isLoading: uiState.verifying,
                onPressed:
                    _resolveAstrometryTarget(detection, preference) == null
                        ? null
                        : () => _verifyAstrometry(
                            _resolveAstrometryTarget(detection, preference)!),
              ),
              isLast: true,
            ),
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: 'Active solver',
          children: [
            _ChoiceRow(
              label: 'ASTAP',
              subtitle:
                  'Fast offline solver — recommended for almost all setups.',
              icon: LucideIcons.zap,
              value: PlateSolverChoice.astap,
              groupValue: preference.choice,
              onChanged: (next) async {
                if (next == null) return;
                await _savePreference(preference.copyWith(choice: next));
              },
            ),
            _ChoiceRow(
              label: 'Astrometry.net',
              subtitle: 'Local solve-field. Slower but useful on Linux/macOS.',
              icon: LucideIcons.globe,
              value: PlateSolverChoice.astrometry,
              groupValue: preference.choice,
              onChanged: (next) async {
                if (next == null) return;
                await _savePreference(preference.copyWith(choice: next));
              },
            ),
            _ChoiceRow(
              label: 'Auto-fallback',
              subtitle: 'Try ASTAP first; fall back to Astrometry.net if ASTAP '
                  'fails or is missing.',
              icon: LucideIcons.shuffle,
              value: PlateSolverChoice.auto,
              groupValue: preference.choice,
              onChanged: (next) async {
                if (next == null) return;
                await _savePreference(preference.copyWith(choice: next));
              },
              isLast: true,
            ),
          ],
        ),
        const SizedBox(height: 16),
        const PlateSolveParametersSection(),
      ],
    );
  }

  /// Resolve which ASTAP path the verify button should run against.
  /// Prefers the user-configured override (preference), then the detected
  /// auto-found path. Returns `null` if neither is set.
  static String? _resolveAstapTarget(
    PlateSolverDetection detection,
    PlateSolverPreference preference,
  ) {
    if (preference.astapPath.isNotEmpty) return preference.astapPath;
    return detection.astapPath;
  }

  static String? _resolveAstrometryTarget(
    PlateSolverDetection detection,
    PlateSolverPreference preference,
  ) {
    if (preference.astrometryPath.isNotEmpty) return preference.astrometryPath;
    return detection.astrometryPath;
  }

  static String _verifyAstapSubtitle({
    required PlateSolverDetection detection,
    required PlateSolverPreference preference,
    required PlateSolverSettingsState uiState,
  }) {
    final target = _resolveAstapTarget(detection, preference);
    if (target == null) {
      return 'No ASTAP path to verify. Browse for one above first.';
    }
    if (uiState.astapVerifyError != null) {
      return 'Last verify failed: ${uiState.astapVerifyError}';
    }
    final info = uiState.astapVerifyInfo;
    if (info != null) {
      return 'OK — ${info.flavour}: ${info.versionLine}';
    }
    return 'Run --help against $target to confirm the binary is healthy.';
  }

  static String _verifyAstrometrySubtitle({
    required PlateSolverDetection detection,
    required PlateSolverPreference preference,
    required PlateSolverSettingsState uiState,
  }) {
    final target = _resolveAstrometryTarget(detection, preference);
    if (target == null) {
      return 'No solve-field path to verify. Browse for one above first.';
    }
    if (uiState.astrometryVerifyError != null) {
      return 'Last verify failed: ${uiState.astrometryVerifyError}';
    }
    final info = uiState.astrometryVerifyInfo;
    if (info != null) {
      return 'OK — ${info.flavour}: ${info.versionLine}';
    }
    return 'Run --help against $target to confirm the binary is healthy.';
  }
}

/// Three-step quick-start visual shown beneath the detection banner when
/// no plate solver is installed yet. Walks the user from "install ASTAP"
/// to "download a catalog" to "re-scan".
class _NoSolverQuickStart extends StatelessWidget {
  static const String _astapDownloadUrl = 'https://www.hnsky.org/astap.htm';
  final VoidCallback? onRescan;
  final bool isRescanning;

  const _NoSolverQuickStart({
    required this.onRescan,
    required this.isRescanning,
  });

  Future<void> _openUrl(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    var launched = false;
    try {
      launched = await canLaunchUrl(uri) &&
          await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (!launched && context.mounted) {
      context.showErrorSnackBar('Could not open $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Get started in 3 steps',
            style: SkotiqTypography.buttonSm.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Skotiq needs a plate solver to centre targets, verify '
            'framing, and run polar alignment. Follow these steps, then '
            'click Re-scan to detect the install.',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          _QuickStartStep(
            stepNumber: 1,
            title: 'Install ASTAP',
            body: 'ASTAP is fast, free, and works fully offline. Click '
                'below to open the download page.',
            icon: LucideIcons.download,
            action: SkotiqButton(
              label: 'Open ASTAP download page',
              icon: LucideIcons.externalLink,
              size: ButtonSize.small,
              variant: ButtonVariant.secondary,
              onPressed: () => _openUrl(context, _astapDownloadUrl),
            ),
            onTap: () => _openUrl(context, _astapDownloadUrl),
          ),
          const SizedBox(height: 10),
          _QuickStartStep(
            stepNumber: 2,
            title: 'Download a star catalog',
            body: 'Grab a catalog from the same page. V17 is recommended '
                'for almost all setups — it covers stars down to mag 17 '
                'and works across the full sky. Drop the catalog next to '
                'astap.exe, or into the folder you will point Skotiq '
                'at below.',
            icon: LucideIcons.database,
            action: SkotiqButton(
              label: 'Open ASTAP catalog page',
              icon: LucideIcons.externalLink,
              size: ButtonSize.small,
              variant: ButtonVariant.secondary,
              onPressed: () => _openUrl(context, _astapDownloadUrl),
            ),
            onTap: () => _openUrl(context, _astapDownloadUrl),
          ),
          const SizedBox(height: 10),
          _QuickStartStep(
            stepNumber: 3,
            title: 'Click re-scan',
            body: 'Once ASTAP and the catalog are installed, click Re-scan '
                'so Skotiq picks them up.',
            icon: LucideIcons.refreshCw,
            action: SkotiqButton(
              label: isRescanning ? 'Re-scanning…' : 'Re-scan now',
              icon: LucideIcons.refreshCw,
              size: ButtonSize.small,
              isLoading: isRescanning,
              onPressed: onRescan,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickStartStep extends StatelessWidget {
  final int stepNumber;
  final String title;
  final String body;
  final IconData icon;
  final Widget action;

  /// Optional tap target for the whole card; used by step 1 / step 2 so the
  /// whole row navigates to the install page, matching the "clickable card"
  /// behaviour called out in the spec.
  final VoidCallback? onTap;

  const _QuickStartStep({
    required this.stepNumber,
    required this.title,
    required this.body,
    required this.icon,
    required this.action,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final card = SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration:
                SkotiqDecorations.chip(colors, tone: colors.primary),
            child: Text(
              '$stepNumber',
              style: SkotiqTypography.buttonSm.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.primary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 14, color: colors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        style: SkotiqTypography.labelStrong
                            .copyWith(color: colors.textPrimary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                action,
              ],
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      child: card,
    );
  }
}

/// Inline hint shown above the ASTAP settings section when ASTAP is
/// detected but no star catalog is found. The directory probed by
/// Skotiq is surfaced verbatim alongside a one-click browse button
/// so the user can point the app at the catalog they already have.
class _CatalogMissingHint extends StatelessWidget {
  final PlateSolverPreference preference;
  final VoidCallback? onBrowseCatalog;
  final bool isBrowsing;

  const _CatalogMissingHint({
    required this.preference,
    required this.onBrowseCatalog,
    required this.isBrowsing,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final probed = preference.catalogPath.isNotEmpty
        ? preference.catalogPath
        : 'the directory containing astap.exe';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.warning,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(LucideIcons.folderSearch, size: 16, color: colors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Searching for catalogs in $probed. If your catalog lives '
              'somewhere else, point Skotiq at it now.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textPrimary,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SkotiqButton(
            label: isBrowsing
                ? 'Choosing catalog directory…'
                : 'Browse for catalog directory',
            icon: LucideIcons.folderOpen,
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            isLoading: isBrowsing,
            onPressed: onBrowseCatalog,
          ),
        ],
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final PlateSolverChoice value;
  final PlateSolverChoice groupValue;
  final ValueChanged<PlateSolverChoice?> onChanged;
  final bool isLast;

  const _ChoiceRow({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final selected = value == groupValue;
    return InkWell(
      onTap: () => onChanged(value),
      child: SettingRow(
        icon: icon,
        title: label,
        subtitle: subtitle,
        trailing: _ChoiceIndicator(selected: selected, colors: colors),
        isLast: isLast,
      ),
    );
  }
}

class _ChoiceIndicator extends StatelessWidget {
  final bool selected;
  final SkotiqColors colors;

  const _ChoiceIndicator({
    required this.selected,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? colors.accent : colors.border,
          width: selected ? 6 : 2,
        ),
        color: colors.surface,
      ),
    );
  }
}
