import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Injectable boundary for the startup installer. Production uses the shared
/// manager; tests can hold individual phases to exercise lifecycle races.
final catalogSetupManagerProvider = Provider<CatalogManager>(
  (ref) => CatalogManager.instance,
);

/// Dialog shown when catalogs need to be downloaded
class CatalogSetupDialog extends ConsumerStatefulWidget {
  final VoidCallback? onSkip;
  final VoidCallback? onComplete;

  const CatalogSetupDialog({
    super.key,
    this.onSkip,
    this.onComplete,
  });

  /// Show the catalog setup dialog
  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CatalogSetupDialog(
        onSkip: () => Navigator.of(context).pop(false),
        onComplete: () => Navigator.of(context).pop(true),
      ),
    );
  }

  @override
  ConsumerState<CatalogSetupDialog> createState() => _CatalogSetupDialogState();
}

class _CatalogSetupDialogState extends ConsumerState<CatalogSetupDialog> {
  /// The one dataset an install delivers. The Essential/Standard/Complete
  /// selector that used to set this fetched identical bytes for all three —
  /// see [CatalogPackage] — while advertising three different star counts and
  /// depths, so it is gone and this is fixed.
  static const CatalogPackage _installedPackage = CatalogPackage.complete;
  bool _isDownloading = false;
  double _progress = 0;
  String _statusMessage = '';
  String? _errorMessage;
  CatalogPackage? _completedStarPackage;

  Future<void> _downloadCatalogs() async {
    if (_isDownloading) return;
    final manager = ref.read(catalogSetupManagerProvider);
    const package = _installedPackage;
    final resumeWithDso = _completedStarPackage == package;
    setState(() {
      _isDownloading = true;
      _progress = resumeWithDso ? 0.5 : 0;
      _statusMessage = resumeWithDso
          ? 'HYG ready — retrying OpenNGC Catalog...'
          : 'Starting download...';
      _errorMessage = null;
    });

    try {
      if (!resumeWithDso) {
        _completedStarPackage = null;
        setState(() => _statusMessage = 'Downloading HYG Star Database...');

        final starSuccess = await manager.downloadStarCatalog(
          package: package,
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                _progress = progress.progress * 0.5;
                if (progress.error != null) {
                  _errorMessage = progress.error;
                }
              });
            }
          },
        );

        if (!mounted) return;
        if (!starSuccess) {
          throw Exception('Star catalog download failed');
        }
        _completedStarPackage = package;
      }

      // Download DSO catalog
      setState(() => _statusMessage = 'Downloading OpenNGC Catalog...');

      final dsoSuccess = await manager.downloadDsoCatalog(
        package: package,
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progress = 0.5 + (progress.progress * 0.5);
              if (progress.error != null) {
                _errorMessage = progress.error;
              }
            });
          }
        },
      );

      if (!mounted) return;
      if (!dsoSuccess) {
        throw Exception('DSO catalog download failed');
      }

      setState(() {
        _progress = 1.0;
        _statusMessage = 'Download complete!';
      });

      // Brief pause to show completion
      await Future.delayed(const Duration(milliseconds: 500));

      if (!mounted) return;
      setState(() => _isDownloading = false);
      widget.onComplete?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _errorMessage = e.toString();
        _statusMessage = 'Download failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg)),
      child: ConstrainedBox(
        constraints: Responsive.dialogConstraints(
          context,
          preferredWidth: 500,
          minWidth: 350,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: SkotiqDecorations.tintedBadge(
                        colors.primary,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusLg),
                      ),
                      child: Icon(
                        Icons.download_rounded,
                        color: colors.primary,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Catalog Setup',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(
                                  color: colors.textPrimary,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Download star and DSO catalogs',
                            style: TextStyle(color: colors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Description
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.background,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'The planetarium requires astronomical catalogs to display stars and deep sky objects.',
                        style: TextStyle(color: colors.textPrimary),
                      ),
                      const SizedBox(height: 12),
                      // One dataset, so one set of figures. These used to
                      // follow a selected tier that changed nothing about the
                      // download.
                      _buildCatalogInfo(
                        colors,
                        'HYG Star Database',
                        '~${formatCatalogCount(kInstalledStarApproxCount)} stars, '
                            'complete to mag ${kHygFaintFloorMag.toStringAsFixed(1)}',
                      ),
                      const SizedBox(height: 8),
                      _buildCatalogInfo(
                        colors,
                        'OpenNGC',
                        '~${formatCatalogCount(kInstalledDsoApproxCount)} DSOs (NGC/IC)',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // No package selection: one dataset, stated above.
                if (!_isDownloading) ...[
                  Text(
                    'About $kInstalledCatalogApproxSizeMB MB on disk.',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // Download progress
                if (_isDownloading) ...[
                  Text(
                    _statusMessage,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                    child: LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: colors.border,
                      valueColor: AlwaysStoppedAnimation(colors.primary),
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${(_progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 24),
                ],

                // Error message
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: SkotiqDecorations.emphasisSurface(
                      colors.error,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            color: colors.error, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(color: colors.error, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Buttons
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (!_isDownloading)
                      SkotiqButton(
                        onPressed: widget.onSkip,
                        label: 'Skip',
                        variant: ButtonVariant.ghost,
                        size: ButtonSize.small,
                      ),
                    SkotiqButton(
                      onPressed: _isDownloading ? null : _downloadCatalogs,
                      label: _isDownloading ? 'Downloading...' : 'Download Now',
                      isLoading: _isDownloading,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCatalogInfo(SkotiqColors colors, String name, String detail) {
    return Row(
      children: [
        Icon(Icons.check_circle, color: colors.primary, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                name,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                detail,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Banner to show when catalogs are not installed
class CatalogRequiredBanner extends StatelessWidget {
  final VoidCallback onSetup;

  const CatalogRequiredBanner({
    super.key,
    required this.onSetup,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.warning,
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colors.warning),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Catalogs Not Installed',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Download star and DSO catalogs to enable full planetarium functionality.',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SkotiqButton(
            onPressed: onSetup,
            label: 'Setup',
          ),
        ],
      ),
    );
  }
}
