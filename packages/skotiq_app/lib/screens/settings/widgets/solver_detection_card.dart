import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Status banner shown at the top of the Plate Solving settings page.
///
/// The primary state follows the user's active [choice]. An installed backup
/// must not make an explicitly selected, unusable solver look ready.
///
/// settings-search: ignore — this card's five headlines ("ASTAP detected …",
/// "ASTAP detected — catalog missing", "ASTAP not installed …", "Selected
/// Astrometry.net solver is not installed", the auto-fallback line) are
/// mutually exclusive reports of what was DETECTED on this machine, and at
/// most one is ever on screen. They are not the names of rows, so the settings
/// search index must not offer them as such: it listed "ASTAP detected —
/// catalog missing" under Plate Solving on a machine whose Plate Solving page
/// said "ASTAP not installed — Skotiq cannot plate-solve".
class SolverDetectionCard extends StatelessWidget {
  static const String astapDownloadUrl = 'https://www.hnsky.org/astap.htm';
  static const String astrometryDownloadUrl = 'https://astrometry.net/use.html';

  final PlateSolverDetection detection;
  final PlateSolverChoice choice;

  /// Optional verify-result info to display alongside the green check.
  /// `null` when the user hasn't yet pressed "Verify".
  final PlateSolverInfo? astapVerifyInfo;

  /// Optional verify-result error message; surfaced inline when verify
  /// fails so the user understands the install is broken even though the
  /// binary exists on disk.
  final String? astapVerifyError;

  final PlateSolverInfo? astrometryVerifyInfo;
  final String? astrometryVerifyError;

  const SolverDetectionCard({
    super.key,
    required this.detection,
    this.choice = PlateSolverChoice.auto,
    this.astapVerifyInfo,
    this.astapVerifyError,
    this.astrometryVerifyInfo,
    this.astrometryVerifyError,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);

    if (choice == PlateSolverChoice.astrometry) {
      return detection.astrometryPath == null
          ? _buildAstrometryMissing(theme, colors)
          : _buildAstrometryReady(theme, colors);
    }

    // Auto prefers ASTAP, but a working Astrometry.net installation is a
    // completely valid ready state when ASTAP is missing or lacks a catalog.
    if (choice == PlateSolverChoice.auto &&
        !detection.astapReady &&
        detection.astrometryPath != null) {
      return _buildAstrometryReady(theme, colors, autoFallback: true);
    }

    if (detection.astapPath == null) {
      return _buildNotInstalled(theme, colors);
    }
    if (!detection.astapReady) {
      return _buildCatalogMissing(theme, colors);
    }
    return _buildReady(theme, colors);
  }

  Widget _buildAstrometryReady(
    ThemeData theme,
    SkotiqColors colors, {
    bool autoFallback = false,
  }) {
    return _CardShell(
      borderColor: colors.success,
      icon: LucideIcons.checkCircle,
      iconColor: colors.success,
      title: autoFallback
          ? 'Astrometry.net ready — Auto fallback active'
          : 'Astrometry.net selected and ready',
      body: [
        Text(
          detection.astrometryPath!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (astrometryVerifyInfo != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(LucideIcons.shieldCheck, size: 14, color: colors.success),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${astrometryVerifyInfo!.flavour}: '
                  '${astrometryVerifyInfo!.versionLine}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.success,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
        if (astrometryVerifyError != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  astrometryVerifyError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (autoFallback) ...[
          const SizedBox(height: 6),
          Text(
            detection.astapPath == null
                ? 'ASTAP is not installed, so Auto will use Astrometry.net.'
                : 'ASTAP has no usable catalog, so Auto will use '
                    'Astrometry.net.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAstrometryMissing(ThemeData theme, SkotiqColors colors) {
    return _CardShell(
      borderColor: colors.error,
      icon: LucideIcons.xCircle,
      iconColor: colors.error,
      title: 'Selected Astrometry.net solver is not installed',
      body: [
        Text(
          detection.astapReady
              ? 'ASTAP is available, but Skotiq will not silently ignore '
                  'your Astrometry.net selection. Install solve-field or '
                  'choose ASTAP / Auto below.'
              : 'Install the solve-field executable or choose another '
                  'available solver below.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        const _LinkText(
          url: astrometryDownloadUrl,
          label: 'Install Astrometry.net (Linux/macOS)',
        ),
      ],
    );
  }

  Widget _buildReady(ThemeData theme, SkotiqColors colors) {
    final catalogName = detection.catalogName ?? '';
    final magLimit = detection.catalogMagnitudeLimit;
    final catalogSuffix = catalogName.isEmpty
        ? ''
        : magLimit == null
            ? ' (catalog: $catalogName)'
            : ' (catalog: $catalogName to mag '
                '${magLimit.toStringAsFixed(0)})';

    return _CardShell(
      borderColor: colors.success,
      icon: LucideIcons.checkCircle,
      iconColor: colors.success,
      title: 'ASTAP detected$catalogSuffix',
      body: [
        Text(
          detection.astapPath!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (astapVerifyInfo != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(LucideIcons.shieldCheck, size: 14, color: colors.success),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${astapVerifyInfo!.flavour}: '
                  '${astapVerifyInfo!.versionLine}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.success,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
        if (astapVerifyError != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  astapVerifyError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (detection.astrometryPath != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(LucideIcons.plus, size: 14, color: colors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Astrometry.net fallback: ${detection.astrometryPath!}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildCatalogMissing(ThemeData theme, SkotiqColors colors) {
    return _CardShell(
      borderColor: colors.warning,
      icon: LucideIcons.alertTriangle,
      iconColor: colors.warning,
      title: 'ASTAP detected — catalog missing',
      body: [
        Text(
          detection.astapPath!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'ASTAP needs a star catalog (V17, D80, G18, …) to solve. Use '
          '"Browse for ASTAP catalog directory" below, or copy a catalog '
          'next to astap.exe.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        const _LinkText(
          url: astapDownloadUrl,
          label: 'Download an ASTAP catalog',
        ),
      ],
    );
  }

  Widget _buildNotInstalled(ThemeData theme, SkotiqColors colors) {
    final hasAstrometry = detection.astrometryPath != null;

    return _CardShell(
      borderColor: colors.error,
      icon: LucideIcons.xCircle,
      iconColor: colors.error,
      title: hasAstrometry
          ? 'ASTAP not installed — only Astrometry.net available'
          : 'ASTAP not installed — Skotiq cannot plate-solve',
      body: [
        if (!hasAstrometry)
          Text(
            'Skotiq needs at least one plate solver to centre targets, '
            'verify framing, and perform polar alignment. ASTAP is the '
            'recommended choice for almost all setups.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textPrimary,
            ),
          )
        else
          Text(
            'Astrometry.net is reachable at '
            '${detection.astrometryPath!}, but ASTAP is the recommended '
            'solver — it is faster and works fully offline. Install ASTAP '
            'and re-scan to switch.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textPrimary,
            ),
          ),
        const SizedBox(height: 6),
        const _LinkText(
          url: astapDownloadUrl,
          label: 'Download ASTAP — hnsky.org',
        ),
        const SizedBox(height: 2),
        const _LinkText(
          url: astrometryDownloadUrl,
          label: 'Install Astrometry.net (Linux/macOS)',
        ),
      ],
    );
  }
}

class _CardShell extends StatelessWidget {
  final Color borderColor;
  final IconData icon;
  final Color iconColor;
  final String title;
  final List<Widget> body;

  const _CardShell({
    required this.borderColor,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: SkotiqDecorations.emphasisSurface(
        borderColor,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                ...body,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkText extends StatelessWidget {
  final String url;
  final String label;

  const _LinkText({
    required this.url,
    required this.label,
  });

  Future<void> _open() async {
    final uri = Uri.parse(url);
    // Why no fallback: install links are static, well-formed https URLs.
    // canLaunchUrl + launchUrl raise on failure so the user gets a real
    // error rather than a silent no-op.
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return InkWell(
      onTap: _open,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.externalLink, size: 12, color: colors.accent),
            const SizedBox(width: 4),
            Text(
              label,
              style: SkotiqTypography.caption.copyWith(
                color: colors.accent,
                decoration: TextDecoration.underline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
