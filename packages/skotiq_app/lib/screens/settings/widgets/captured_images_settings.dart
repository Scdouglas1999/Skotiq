import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
// `ConnectionState` collides with Flutter's FutureBuilder enum; we only use
// Flutter's here.
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import 'settings_widgets.dart';
import '../../../utils/image_decode_size.dart';

/// Browse the frames captured on the connected appliance.
///
/// The headless server already serves the listing (`GET /api/images`),
/// thumbnails (`/api/images/<id>/thumbnail`), and downloads — there just was no
/// mobile UI consuming them, so a remote operator could not see what the rig
/// had shot. This grid fetches thumbnails on demand (cached) and shows frame
/// metadata. Remote-only; the local desktop has its own image browser.
class CapturedImagesSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const CapturedImagesSettings({super.key, this.isMobile = false});

  @override
  ConsumerState<CapturedImagesSettings> createState() =>
      _CapturedImagesSettingsState();
}

class _CapturedImagesSettingsState
    extends ConsumerState<CapturedImagesSettings> {
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = false;
  String? _error;
  final Map<int, Uint8List> _thumbCache = {};
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _loadGeneration = 0;

  NetworkBackend? get _backend {
    final b = ref.read(backendProvider);
    return b is NetworkBackend ? b : null;
  }

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _loadGeneration++;
        setState(() {
          _rows = const [];
          _thumbCache.clear();
          _error = null;
          _loading = next is NetworkBackend;
        });
        if (next is NetworkBackend) unawaited(_refresh());
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    final backend = _backend;
    final generation = ++_loadGeneration;
    if (backend == null) {
      if (!mounted) return;
      setState(() {
        _rows = const [];
        _thumbCache.clear();
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await backend.getAllImageRows();
      if (!mounted ||
          generation != _loadGeneration ||
          !identical(ref.read(backendProvider), backend)) {
        return;
      }
      setState(() {
        _rows = rows;
        _thumbCache.clear();
        _loading = false;
      });
    } catch (e) {
      if (!mounted ||
          generation != _loadGeneration ||
          !identical(ref.read(backendProvider), backend)) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  int? _idOf(Map<String, dynamic> row) {
    final v = row['id'] ?? row['imageId'];
    final int? id;
    if (v is int) {
      id = v;
    } else if (v is num && v.isFinite && v == v.truncateToDouble()) {
      id = v.toInt();
    } else if (v is String && RegExp(r'^[1-9][0-9]*$').hasMatch(v)) {
      id = int.tryParse(v);
    } else {
      id = null;
    }
    return id != null && id > 0 ? id : null;
  }

  String _labelOf(Map<String, dynamic> row) {
    final target = row['targetName'] ?? row['target'];
    final filter = row['filter'];
    final file = row['fileName'] ?? row['filename'] ?? row['path'];
    final parts = <String>[
      if (target is String && target.isNotEmpty) target,
      if (filter is String && filter.isNotEmpty) filter,
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    if (file is String && file.isNotEmpty) return file.split('/').last;
    return 'Frame';
  }

  Future<Uint8List> _thumb(int id) async {
    final cached = _thumbCache[id];
    if (cached != null) return cached;
    final backend = _backend;
    if (backend == null) {
      throw StateError('No remote imaging host is connected');
    }
    final bytes = await backend.getImageThumbnail(id);
    if (!mounted || !identical(ref.read(backendProvider), backend)) {
      throw StateError('The imaging host changed while loading the thumbnail');
    }
    _thumbCache[id] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final backend = _backend;

    return SettingsPage(
      title: 'Captured images',
      description: 'Browse frames captured on the connected appliance',
      isMobile: widget.isMobile,
      hideHeader: widget.isMobile,
      children: [
        if (backend == null)
          _info(colors, LucideIcons.info,
              'Connect to a remote appliance to browse its captured frames.')
        else ...[
          Row(
            children: [
              Text('${_rows.length} frame${_rows.length == 1 ? '' : 's'}',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  )),
              const Spacer(),
              SkotiqButton(
                onPressed: _loading ? null : _refresh,
                label: 'Refresh',
                icon: LucideIcons.rotateCw,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading && _rows.isEmpty)
            _info(colors, LucideIcons.loader, 'Loading…')
          else if (_error != null && _rows.isEmpty)
            _loadError(colors)
          else if (_rows.isEmpty)
            _info(colors, LucideIcons.image,
                'No frames captured on the appliance yet.')
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: widget.isMobile ? 120 : 160,
                childAspectRatio: 1,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: _rows.length,
              itemBuilder: (context, i) {
                final row = _rows[i];
                final id = _idOf(row);
                return _GalleryTile(
                  colors: colors,
                  label: _labelOf(row),
                  accepted: row['isAccepted'] == true,
                  thumb: id == null ? null : () => _thumb(id),
                  onTap: id == null ? null : () => _showFull(id, _labelOf(row)),
                  unavailableReason: id == null
                      ? 'This frame has an invalid image ID and cannot be opened.'
                      : null,
                );
              },
            ),
          if (_error != null && _rows.isNotEmpty) ...[
            const SizedBox(height: 12),
            _loadError(colors),
          ],
        ],
      ],
    );
  }

  Future<void> _showFull(int id, String label) async {
    final Uint8List bytes;
    try {
      bytes = await _thumb(id);
    } catch (_) {
      if (mounted) {
        context.showErrorSnackBar('Could not load $label. Try again.');
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: ImageOverlayColors.shadow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Text(label,
                      style: SkotiqTypography.bodySm.copyWith(
                        color: ImageOverlayColors.foreground,
                      )),
                  const SizedBox(height: 2),
                  // The appliance only serves a JPEG thumbnail sidecar; the
                  // full frame is raw FITS (`/download`) that can't render
                  // inline. Say so rather than passing the thumbnail off as
                  // the capture.
                  Text(
                    'Full-frame preview unavailable — showing the thumbnail. '
                    'Download the frame to inspect it at full resolution.',
                    textAlign: TextAlign.center,
                    style: SkotiqTypography.captionSm.copyWith(
                      color: ImageOverlayColors.secondary,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(child: InteractiveViewer(child: Image.memory(bytes))),
          ],
        ),
      ),
    );
  }

  Widget _info(SkotiqColors colors, IconData icon, String text) {
    return SkotiqPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                )),
          ),
        ],
      ),
    );
  }

  Widget _loadError(SkotiqColors colors) {
    return SkotiqPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle, size: 18, color: colors.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Could not load captured frames: $_error',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SkotiqButton(
            onPressed: _loading ? null : _refresh,
            label: 'Retry',
            icon: LucideIcons.rotateCw,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
        ],
      ),
    );
  }
}

class _GalleryTile extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final bool accepted;
  final Future<Uint8List> Function()? thumb;
  final VoidCallback? onTap;
  final String? unavailableReason;

  const _GalleryTile({
    required this.colors,
    required this.label,
    required this.accepted,
    required this.thumb,
    required this.onTap,
    required this.unavailableReason,
  });

  @override
  Widget build(BuildContext context) {
    final tile = GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: colors.background),
            if (thumb != null)
              FutureBuilder<Uint8List>(
                future: thumb!(),
                builder: (context, snap) {
                  final bytes = snap.data;
                  if (bytes == null) {
                    return Center(
                      child: snap.hasError
                          ? Tooltip(
                              message:
                                  'Thumbnail failed to load. Tap to retry.',
                              child: Icon(
                                LucideIcons.alertTriangle,
                                size: 20,
                                color: colors.error,
                              ),
                            )
                          : snap.connectionState == ConnectionState.done
                              ? Icon(
                                  LucideIcons.imageOff,
                                  size: 20,
                                  color: colors.textMuted,
                                )
                              : const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: SkotiqMark(size: 18)),
                    );
                  }
                  // Gallery tile, not an inspection surface: decode at tile
                  // width so a long session's grid does not hold a megabyte of
                  // RGBA per cell.
                  return LayoutBuilder(
                    builder: (context, constraints) => Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      cacheWidth: thumbnailDecodeWidth(
                        context,
                        constraints.maxWidth,
                      ),
                    ),
                  );
                },
              ),
            if (thumb == null)
              Center(
                child: Icon(
                  LucideIcons.imageOff,
                  size: 20,
                  color: colors.textMuted,
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                color: ImageOverlayColors.scrim,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.captionSm.copyWith(
                    color: ImageOverlayColors.foreground,
                  ),
                ),
              ),
            ),
            if (!accepted)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(LucideIcons.xCircle, size: 14, color: colors.error),
              ),
          ],
        ),
      ),
    );
    final reason = unavailableReason;
    return reason == null ? tile : Tooltip(message: reason, child: tile);
  }
}
