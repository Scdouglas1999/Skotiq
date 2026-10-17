import 'dart:io';

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Displays a finished integrated master's stretched preview PNG with zoom / pan
/// and an optional rejection-map overlay toggle.
///
/// The native integration pipeline writes the master FITS plus an already-
/// stretched preview PNG (and, when enabled, a rejection-map PNG); this viewer
/// loads those artifacts from disk. It is the post-session analogue of the
/// live-stack [StackResultScreen] viewer, but reads the on-disk preview rather
/// than an in-memory buffer (the batch master never lives in the Dart heap).
class MasterPreviewView extends StatefulWidget {
  /// Path to the stretched preview PNG (required to render anything).
  final String? previewPath;

  /// Path to the rejection-map PNG, enabling the overlay toggle when present.
  final String? rejectionMapPngPath;

  /// Integration stat line shown under the image.
  final String? statLine;

  const MasterPreviewView({
    super.key,
    required this.previewPath,
    this.rejectionMapPngPath,
    this.statLine,
  });

  /// Build from a fresh integration outcome.
  factory MasterPreviewView.fromOutcome(PostSessionIntegrationOutcome outcome) {
    final r = outcome.result;
    return MasterPreviewView(
      previewPath: r.previewPath,
      rejectionMapPngPath: r.rejectionMapPreviewPath,
      statLine: '${r.framesIntegrated} frames · ${r.framesRejected} rejected · '
          '${formatHms(r.totalIntegrationSec)} · '
          'residual ${r.rmsResidual.toStringAsFixed(2)} px',
    );
  }

  /// Build from a persisted master row.
  static Widget fromMaster(IntegratedMaster master) {
    return MasterPreviewView(
      previewPath: master.previewPngPath,
      rejectionMapPngPath: master.rejectionMapPreviewPath,
      statLine: '${master.frameCount} frames · '
          '${formatHms(master.totalIntegrationSeconds)} · '
          '${master.width}×${master.height}',
    );
  }

  @override
  State<MasterPreviewView> createState() => _MasterPreviewViewState();
}

class _MasterPreviewViewState extends State<MasterPreviewView> {
  bool _showRejection = false;

  bool _exists(String? path) {
    if (path == null) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final hasPreview = _exists(widget.previewPath);
    final hasRejection = _exists(widget.rejectionMapPngPath);

    if (!hasPreview) {
      return EmptyState(
        icon: SkotiqIcons.imageOff,
        title: 'Preview not available',
        body: widget.previewPath == null
            ? 'This master has no preview yet. Finalize it to generate one.'
            : 'The preview file is no longer on disk:\n${widget.previewPath}',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasRejection)
          Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            child: Row(
              children: [
                Text(
                  'Rejection overlay',
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textSecondary),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                SkotiqSwitch(
                  value: _showRejection,
                  compact: true,
                  onChanged: (v) => setState(() => _showRejection = v),
                ),
              ],
            ),
          ),
        Expanded(
          child: Container(
            color: colors.background,
            padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
            child: InteractiveViewer(
              maxScale: 8,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    File(widget.previewPath!),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Center(
                      child: Icon(SkotiqIcons.imageOff,
                          size: 48, color: colors.textMuted),
                    ),
                  ),
                  if (_showRejection && hasRejection)
                    Opacity(
                      opacity: 0.55,
                      child: Image.file(
                        File(widget.rejectionMapPngPath!),
                        fit: BoxFit.contain,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (widget.statLine != null)
          Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            child: Text(
              widget.statLine!,
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ),
      ],
    );
  }
}
