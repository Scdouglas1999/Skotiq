// Shared installed-catalog card and status-chip presentation helpers.
part of '../catalog_settings_screen.dart';

mixin _CatalogCardBuilders on ConsumerState<CatalogSettingsScreen> {
  bool get _isDownloading;

  Future<void> _importCatalog(String type);

  String _formatDate(DateTime date);

  /// Whether an appliance-reported catalog status counts as usable there.
  static bool _rigHasCatalog(String status) =>
      status == 'installed' || status == 'ok';

  /// [rigStatus] is the connected appliance's status for this catalog, or null
  /// for a local session. When it is set, the install badges name WHICH machine
  /// holds the catalog — an unqualified "Installed" read off this device's own
  /// filesystem is a claim about the wrong machine.
  Widget _buildCatalogCard({
    required BuildContext context,
    required String title,
    required String description,
    required String sourceUrl,
    required CatalogStatus? status,
    required String type,
    required IconData icon,
    required String usedFor,
    String? latestVersion,
    String? rigStatus,
  }) {
    final colors = context.skotiqColors;
    final isInstalled = status?.isInstalled ?? false;
    // Only a version the app can actually FETCH and that is genuinely NEWER
    // than the installed one earns the badge. This was `!=` against a hardcoded
    // literal that had gone stale when HYG rolled to v4.4: the newest asset the
    // resolver knows about was flagged "Update available" against itself,
    // because 4.4 is not equal to the 4.2 the screen still named. See
    // [_isNewerCatalogVersion].
    final updateAvailable = isInstalled &&
        latestVersion != null &&
        status?.version != null &&
        _isNewerCatalogVersion(status!.version!, latestVersion);

    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon,
                  color: colors.textMuted, size: SkotiqTokens.iconMd),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          title,
                          style: SkotiqTypography.sectionTitle
                              .copyWith(color: colors.textPrimary),
                        ),
                        if (isInstalled)
                          _buildBadge(
                            context: context,
                            label: rigStatus == null
                                ? 'Installed'
                                : 'On this device',
                            color: colors.success,
                          ),
                        if (rigStatus != null)
                          _buildBadge(
                            context: context,
                            label: _rigHasCatalog(rigStatus)
                                ? 'On the rig'
                                : 'Not on the rig',
                            color: _rigHasCatalog(rigStatus)
                                ? colors.success
                                : colors.warning,
                          ),
                        if (updateAvailable)
                          _buildBadge(
                            context: context,
                            label: 'Update available',
                            color: colors.warning,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              SkotiqIconButton(
                icon: SkotiqIcons.folderOpen,
                tooltip: 'Import from file',
                onPressed: _isDownloading ? null : () => _importCatalog(type),
                size: IconButtonSize.sm,
                color: colors.textSecondary,
              ),
            ],
          ),
          const SizedBox(height: 10),
          // What this catalog powers — helps users decide whether they need it.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(SkotiqIcons.info,
                  size: 14, color: colors.textSecondary.withValues(alpha: 0.8)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  usedFor,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary.withValues(alpha: 0.9),
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Source: $sourceUrl',
            style: SkotiqTypography.monoCaption.copyWith(
              color: colors.textSecondary.withValues(alpha: 0.7),
            ),
          ),
          if (isInstalled && status != null) ...[
            const SizedBox(height: 12),
            Divider(color: colors.border),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _buildStatusChip(
                  context: context,
                  label: 'Objects',
                  value: _formatCount(status.objectCount),
                ),
                _buildStatusChip(
                  context: context,
                  label: 'Size',
                  value: _formatBytes(status.fileSizeBytes),
                ),
                if (status.version != null)
                  _buildStatusChip(
                    context: context,
                    label: 'Version',
                    value: status.version!,
                  ),
                // No "Package" chip. It printed the download TIER off the
                // metadata sidecar — Essential / Standard / Complete — and the
                // tiers were retired because they were a placebo: all three
                // downloaded the same bytes (byte-identical SHA-256 for an
                // `essential` and a `standard` sidecar). A grade the user can
                // no longer choose, that never described anything, is not a
                // fact about their install. Everything the sidecar can honestly
                // say is already on the card: the dataset name is the title and
                // the object count, size, version and install date are chips.
                if (_magnitudeDepth(type, status.installedPackage) != null)
                  _buildStatusChip(
                    context: context,
                    label: 'Depth',
                    value: _magnitudeDepth(type, status.installedPackage)!,
                  ),
                if (status.installedDate != null)
                  _buildStatusChip(
                    context: context,
                    label: 'Installed',
                    value: _formatDate(status.installedDate!),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Small rounded status/label badge (e.g. "Installed", "Update available").
  Widget _buildBadge({
    required BuildContext context,
    required String label,
    required Color color,
  }) {
    return SkotiqChip(
        label: label,
        tone: color == context.skotiqColors.success
            ? ChipTone.success
            : ChipTone.warning);
  }

  /// Human-readable magnitude depth for the installed catalog, or null when
  /// there is no honest depth to state.
  ///
  /// Stars quote [kHygFaintFloorMag] — HYG's real completeness, the same number
  /// the Deep-Star card and the Layers panel quote. This read the depth off the
  /// metadata sidecar's package name, so the SAME installed file reported
  /// "mag ≤ 6.5" or "mag ≤ 8.0" depending on which fictitious tier had been
  /// clicked at download time.
  ///
  /// DSOs get no depth chip. OpenNGC is a compilation, not a magnitude-limited
  /// survey, so there is no magnitude it is complete to; the card's measured
  /// Objects count and file size already say what is installed.
  String? _magnitudeDepth(String type, CatalogPackage? package) {
    if (package == null) return null;
    if (type == 'stars') {
      return 'mag ≤ ${kHygFaintFloorMag.toStringAsFixed(1)}';
    }
    return null;
  }

  /// Whether [fetchable] names a catalog release genuinely NEWER than
  /// [installed] — the only case in which "Update available" is true.
  ///
  /// Catalog versions are dotted numeric strings, either a release number
  /// (`4.2`, `4.4`) or a year-month stamp (`2023.12`), so components are
  /// compared numerically and left to right; a shorter version is treated as
  /// zero-padded (`4` < `4.1`). Anything that does not parse as numbers falls
  /// back to "not newer": an unrecognised string is not evidence of an update,
  /// and the badge exists to send the user to a download that will actually
  /// give them something they do not have.
  ///
  /// The predicate this replaced was `installed != latest` against a hardcoded
  /// literal on the screen. When HYG rolled from v4.2 to v4.4 the constant in
  /// [catalogDownloadCandidates] moved and the one on the card did not, so a
  /// fresh install of the newest asset the app can fetch wore a permanent amber
  /// "Update available" pointing at a version that no longer exists.
  static bool _isNewerCatalogVersion(String installed, String fetchable) {
    if (installed == fetchable) return false;
    final a = _versionComponents(installed);
    final b = _versionComponents(fetchable);
    if (a == null || b == null) return false;
    for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
      final lhs = i < a.length ? a[i] : 0;
      final rhs = i < b.length ? b[i] : 0;
      if (rhs > lhs) return true;
      if (rhs < lhs) return false;
    }
    return false;
  }

  /// `"2023.12"` -> `[2023, 12]`; null when any component is not an integer.
  static List<int>? _versionComponents(String version) {
    final trimmed = version.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split('.');
    final out = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null) return null;
      out.add(value);
    }
    return out;
  }

  String _formatCount(int? count) {
    if (count == null) return 'Unknown';
    if (count < 1000) return '$count';
    if (count < 1000000) return '${(count / 1000).toStringAsFixed(1)}k';
    return '${(count / 1000000).toStringAsFixed(1)}M';
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return 'Unknown';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Widget _buildStatusChip({
    required BuildContext context,
    required String label,
    required String value,
  }) {
    return Readout(value: value, label: label, size: ReadoutSize.sm);
  }
}
