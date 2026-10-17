import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/confirm_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/gated_action.dart';

final deepStarCatalogManagerProvider = Provider<DeepStarCatalogManager>(
  (ref) => DeepStarCatalogManager(),
);

/// Settings card for the downloadable **deep-star tier** (Tycho-2 / Gaia subset
/// below the bundled HYG floor).
///
/// Lets the user point at a self-hosted tileset base URL, download it with a
/// hash-verified progress bar, see install status, verify, and delete. The
/// tier renders only when zoomed in past the deep-star FOV threshold and the
/// "Deep stars" layer is enabled.
class DeepStarCatalogCard extends ConsumerStatefulWidget {
  const DeepStarCatalogCard({super.key});

  @override
  ConsumerState<DeepStarCatalogCard> createState() =>
      _DeepStarCatalogCardState();
}

class _DeepStarCatalogCardState extends ConsumerState<DeepStarCatalogCard> {
  late final DeepStarCatalogManager _manager;
  late final TextEditingController _urlController = TextEditingController();

  DeepStarStatus? _status;
  bool _loading = true;
  Object? _loadError;
  _DeepStarAction? _action;
  DeepStarDownloadProgress? _progress;
  bool _cancelRequested = false;
  bool _deleteConfirmationOpen = false;
  int _refreshGeneration = 0;

  bool get _busy => _action != null;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(deepStarCatalogManagerProvider);
    _refresh();
  }

  @override
  void dispose() {
    _cancelRequested = true;
    _refreshGeneration++;
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final results = await Future.wait<Object>([
        _manager.getBaseUrl(),
        _manager.status(),
      ]);
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _urlController.text = results[0] as String;
        _status = results[1] as DeepStarStatus;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _loading = false;
        _loadError = e;
      });
    }
  }

  Future<void> _download() async {
    if (_busy || _deleteConfirmationOpen) return;
    setState(() {
      _action = _DeepStarAction.download;
      _cancelRequested = false;
      _progress = null;
    });
    try {
      await _manager.setBaseUrl(_urlController.text.trim());
      final ok = await _manager.download(
        onProgress: (p) {
          if (mounted && _action == _DeepStarAction.download) {
            setState(() => _progress = p);
          }
        },
        isCancelled: () async => _cancelRequested,
      );
      if (!mounted) return;
      if (ok) {
        // Force the renderer's manifest provider to re-read.
        ref.read(deepStarManifestRefreshProvider.notifier).state++;
        ref.read(showDeepStarsProvider.notifier).state = true;
        context.showSuccessSnackBar('Deep-star tiles installed');
      } else {
        context.showInfoSnackBar('Download paused — resume any time');
      }
    } catch (e) {
      if (mounted) context.showErrorSnackBar('Download failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _action = null;
          _progress = null;
        });
        await _refresh();
      }
    }
  }

  Future<void> _verify() async {
    if (_busy || _deleteConfirmationOpen) return;
    setState(() => _action = _DeepStarAction.verify);
    try {
      final result = await _manager.verify();
      if (!mounted) return;
      if (result.ok) {
        context
            .showSuccessSnackBar('All ${result.tilesChecked} tiles verified');
      } else {
        context.showErrorSnackBar(
            '${result.missing.length} missing, ${result.corrupt.length} corrupt');
      }
    } catch (e) {
      if (mounted) context.showErrorSnackBar('Verification failed: $e');
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  Future<void> _delete() async {
    if (_busy || _deleteConfirmationOpen) return;
    setState(() => _deleteConfirmationOpen = true);
    final bool confirm;
    try {
      confirm = await ConfirmDialog.show(
        context: context,
        title: 'Delete deep-star tiles',
        message: 'Remove the downloaded deep-star tier? The bundled HYG stars '
            'are unaffected.',
        confirmLabel: 'Delete',
        isDestructive: true,
      );
    } finally {
      if (mounted) setState(() => _deleteConfirmationOpen = false);
    }
    if (!mounted) return;
    if (!confirm) return;
    setState(() => _action = _DeepStarAction.delete);
    try {
      await _manager.delete();
      if (!mounted) return;
      ref.read(deepStarManifestRefreshProvider.notifier).state++;
      ref.read(showDeepStarsProvider.notifier).state = false;
      context.showInfoSnackBar('Deep-star tiles deleted');
    } catch (e) {
      if (!mounted) return;
      // Deletion is best-effort, so some files may have been removed even
      // when the manager reports that others were locked or inaccessible.
      ref.read(deepStarManifestRefreshProvider.notifier).state++;
      context.showErrorSnackBar('Deletion incomplete: $e');
    } finally {
      if (mounted) {
        setState(() => _action = null);
        await _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final status = _status;
    final isInstalled = status?.isInstalled ?? false;
    final hasCatalogData = status?.hasCatalogData ?? false;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(
          color: isInstalled
              ? colors.success.withValues(alpha: 0.3)
              : colors.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.star, color: colors.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Deep-Star Tier (Tycho-2 / Gaia)',
                  style: SkotiqTypography.sectionTitle
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              if (hasCatalogData)
                _Badge(
                  label: status!.isComplete ? 'Installed' : 'Partial',
                  color: status.isComplete ? colors.success : colors.warning,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            // The floor is quoted from kHygFaintFloorMag, the same constant the
            // HYG/deep-tier merge seam and the Layers panel use.
            'Streams faint stars below the bundled HYG floor '
            '(mag ${kHygFaintFloorMag.toStringAsFixed(1)}) as view-culled '
            'tiles when zoomed in. No tileset is published yet: host one built '
            'with tools/catalog_prep and point the URL below at it.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_loadError != null)
            _LoadError(
              error: _loadError!,
              onRetry: _refresh,
            )
          else ...[
            TextField(
              controller: _urlController,
              enabled: !_busy,
              // Rebuild so the Download button enables as soon as a URL is
              // typed (and the helper note below disappears).
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Tileset base URL',
                hintText: 'https://your-host/skotiq_deep_stars',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary,
              ),
            ),
            if (_urlController.text.trim().isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'No official tileset is published yet — point this at a '
                'tileset you host yourself (see tools/catalog_prep in the '
                'Skotiq repository).',
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
            if (isInstalled) ...[
              const SizedBox(height: 12),
              Text(
                '${status!.manifest!.totalStars} stars across '
                '${status.tilesPresent}/${status.manifest!.tiles.length} tiles'
                '${status.installedAt != null ? " • installed ${_fmt(status.installedAt!)}" : ""}',
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textSecondary.withValues(alpha: 0.8),
                ),
              ),
            ] else if (hasCatalogData) ...[
              const SizedBox(height: 12),
              Text(
                'A partial or unreadable download is present. Resume it or '
                'delete it to reclaim the files.',
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.warning,
                ),
              ),
            ],
            if (_busy && _progress != null) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline4),
                child: LinearProgressIndicator(
                  value: _progress!.fraction,
                  backgroundColor: colors.border,
                  valueColor: AlwaysStoppedAnimation(colors.primary),
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${_progress!.verifying ? "Verifying" : "Downloading"} '
                '${_progress!.tilesDone}/${_progress!.tilesTotal} • '
                '${(_progress!.bytesDone / 1024).toStringAsFixed(0)} KiB',
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                Builder(builder: (context) {
                  final label = _action == _DeepStarAction.download
                      ? (_cancelRequested ? 'Stopping…' : 'Downloading…')
                      : (hasCatalogData ? 'Re-download / Resume' : 'Download');
                  // `onPressed: null` alone is invisible to a tree dump: the
                  // control still reads as a plain `button: Download` with no
                  // `[DISABLED]`, indistinguishable from a live button whose
                  // click is swallowed. With the reason in the accessible
                  // NAME, the dump says which of the two is true.
                  final blocked = _urlController.text.trim().isEmpty
                      ? 'no tileset URL is set, so there is nothing to '
                          'download from'
                      : null;
                  return GatedAction(
                    label: label,
                    blockedReason: _busy ? null : blocked,
                    child: SkotiqButton(
                      label: label,
                      icon: SkotiqIcons.download,
                      variant: ButtonVariant.secondary,
                      // Disabled until a host is entered: with no URL the
                      // request can only fail, so don't offer it.
                      onPressed: (_busy || blocked != null) ? null : _download,
                    ),
                  );
                }),
                if (_action == _DeepStarAction.download)
                  SkotiqButton(
                    label: 'Pause',
                    icon: SkotiqIcons.close,
                    variant: ButtonVariant.secondary,
                    onPressed: _cancelRequested
                        ? null
                        : () => setState(() => _cancelRequested = true),
                  ),
                if (isInstalled)
                  SkotiqButton(
                    label: 'Verify',
                    icon: SkotiqIcons.success,
                    variant: ButtonVariant.secondary,
                    isLoading: _action == _DeepStarAction.verify,
                    onPressed:
                        (_busy || _deleteConfirmationOpen) ? null : _verify,
                  ),
                if (hasCatalogData)
                  SkotiqButton(
                    label: 'Delete',
                    icon: SkotiqIcons.delete,
                    variant: ButtonVariant.destructive,
                    isLoading: _action == _DeepStarAction.delete,
                    onPressed:
                        (_busy || _deleteConfirmationOpen) ? null : _delete,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

enum _DeepStarAction { download, verify, delete }

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Deep-star catalog unavailable',
          style: SkotiqTypography.bodyMedium.copyWith(
            color: colors.error,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          error.toString(),
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        SkotiqButton(
          label: 'Retry',
          icon: SkotiqIcons.refresh,
          variant: ButtonVariant.secondary,
          onPressed: onRetry,
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Text(label,
          style: SkotiqTypography.labelQuiet.copyWith(color: color)),
    );
  }
}
