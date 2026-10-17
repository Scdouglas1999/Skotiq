/// Frame-Failure Forensics: detail dialog.
///
/// Modal that shows the rejected frame's preview, the grader's reason
/// string, the classifier's verdict + evidence bullets, and the
/// environment snapshot from the moment of capture.
///
/// Opens from two surfaces:
///
/// * The thumbnail strip — tapping a rejected thumbnail.
/// * The Forensics panel — tapping a row.
///
/// Both call `showDialog(builder: (_) => FrameDetailDialog(record: r))`.
///
/// The image preview is best-effort: when the `reject_path` is a valid
/// file URI we try to render via [Image.file]; on iOS/Android sandboxes
/// where the path is not directly accessible we fall back to a stub
/// card showing the path string + a "Show in file manager" hint (the
/// underlying file is still on the imaging laptop / desktop disk).

library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../widgets/frame_thumbnail_loader.dart';
import 'forensics_panel.dart' show forensicsCauseColor;

class FrameDetailDialog extends StatelessWidget {
  final FrameForensicsRecord record;

  /// Optional "last accepted frame" record used by the compare-mode
  /// toggle. When `null` the toggle is hidden.
  final FrameForensicsRecord? lastAcceptedReference;

  const FrameDetailDialog({
    super.key,
    required this.record,
    this.lastAcceptedReference,
  });

  /// Look up the forensic record for [imageId] and open the detail
  /// dialog. Replay Debug uses this to jump directly from a
  /// FrameRejected decision row into the same forensics UI as the run
  /// dashboard.
  static Future<void> showForFrame(
    BuildContext context, {
    required int imageId,
  }) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final service = container.read(forensicsServiceProvider);
    final record = await service.loadForCapturedImage(imageId);
    if (!context.mounted) return;
    if (record == null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No forensic record'),
          content: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              ctx,
              designMaxWidth: 480,
            ),
            child: Text(
              'No frame-forensics record is linked to captured image $imageId.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => FrameDetailDialog(record: record),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final causeColor = forensicsCauseColor(record.likelyCause, colors);
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 720,
      designHeight: 640,
    );
    return Dialog(
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Padding(
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(record: record, causeColor: causeColor, colors: colors),
              const SizedBox(height: SkotiqTokens.spaceLg),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: _ImagePreview(
                        rejectPath: record.rejectPath,
                        capturedImageId: record.capturedImageId,
                        colors: colors,
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceLg),
                    Expanded(
                      flex: 5,
                      child: SingleChildScrollView(
                        child: _DetailSidePanel(
                          record: record,
                          causeColor: causeColor,
                          colors: colors,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(LucideIcons.x, size: 14),
                  label: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final FrameForensicsRecord record;
  final Color causeColor;
  final SkotiqColors colors;

  const _Header({
    required this.record,
    required this.causeColor,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
          decoration: SkotiqDecorations.statusChip(
            causeColor,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
            bordered: false,
          ),
          child: Icon(LucideIcons.alertOctagon, size: 18, color: causeColor),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Why did this fail?',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: colors.textMuted,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                record.likelyCause.humanLabel,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize18,
                  fontWeight: FontWeight.w700,
                  color: causeColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Frame ${record.frameIndex}/${record.totalFrames} • '
                'Captured ${_formatDateTime(record.createdAt)}',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ImagePreview extends ConsumerWidget {
  final String rejectPath;
  final int? capturedImageId;
  final SkotiqColors colors;

  const _ImagePreview({
    required this.rejectPath,
    required this.capturedImageId,
    required this.colors,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (capturedImageId != null) {
      return FutureBuilder<Uint8List?>(
        future: fetchFrameThumbnailBytes(
          ref,
          capturedImageId!,
          source: 'RunDashboardFrameDetail',
        ),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.textMuted,
                ),
              ),
            );
          }
          final bytes = snapshot.data;
          if (bytes != null && bytes.isNotEmpty) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    _PathFallback(path: rejectPath, colors: colors),
              ),
            );
          }
          return _localOrFallbackPreview(context, ref);
        },
      );
    }
    return _localOrFallbackPreview(context, ref);
  }

  Widget _localOrFallbackPreview(BuildContext context, WidgetRef ref) {
    if (ref.watch(isRemoteModeProvider)) {
      return _PathFallback(
        path: rejectPath,
        colors: colors,
        subtitle:
            'Preview loads from the imaging host when a thumbnail is available.',
      );
    }

    final file = File(rejectPath);
    final exists = _safeExists(file);
    if (!exists) {
      return _PathFallback(path: rejectPath, colors: colors);
    }
    // The reject FITS itself isn't directly viewable as an Image; the
    // thumbnail strip typically writes a sidecar PNG. Look for it
    // alongside the FITS.
    final preview = _resolvePreviewFile(rejectPath);
    if (preview != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        child: Image.file(
          preview,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              _PathFallback(path: rejectPath, colors: colors),
        ),
      );
    }
    return _PathFallback(path: rejectPath, colors: colors);
  }

  bool _safeExists(File f) {
    try {
      return f.existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Look for the sidecar preview that the thumbnail strip writes
  /// alongside each FITS. Convention: same basename with the
  /// FITS extension swapped for `.preview.png`.
  File? _resolvePreviewFile(String rejectPath) {
    final lower = rejectPath.toLowerCase();
    for (final ext in ['.fits', '.fit', '.fts', '.xisf']) {
      if (lower.endsWith(ext)) {
        final preview =
            File('${rejectPath.substring(0, rejectPath.length - ext.length)}'
                '.preview.png');
        if (_safeExists(preview)) return preview;
      }
    }
    return null;
  }
}

class _PathFallback extends StatelessWidget {
  final String path;
  final SkotiqColors colors;
  final String? subtitle;

  const _PathFallback({
    required this.path,
    required this.colors,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(LucideIcons.image, size: 36, color: colors.textMuted),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            'Preview unavailable',
            style: SkotiqTypography.h6.copyWith(color: colors.textSecondary),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                color: colors.textMuted,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceSm),
          SelectableText(
            path,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              color: colors.textMuted,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailSidePanel extends StatelessWidget {
  final FrameForensicsRecord record;
  final Color causeColor;
  final SkotiqColors colors;

  const _DetailSidePanel({
    required this.record,
    required this.causeColor,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final env = record.environment;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SectionHeader(label: 'GRADER REASON', colors: colors),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          record.reason,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize12,
            color: colors.textPrimary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _SectionHeader(label: 'EVIDENCE', colors: colors),
        const SizedBox(height: SkotiqTokens.spaceSm),
        if (record.evidence.isEmpty)
          Text(
            'No structured evidence — classifier could not muster a verdict.',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              fontStyle: FontStyle.italic,
              color: colors.textMuted,
            ),
          )
        else
          ...record.evidence.map(
            (bullet) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: causeColor,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusInline2),
                      ),
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Text(
                      bullet,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: colors.textPrimary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _SectionHeader(label: 'FRAME METRICS', colors: colors),
        const SizedBox(height: SkotiqTokens.spaceSm),
        _MetricsGrid(
          rows: [
            ('HFR', _formatNumber(record.hfr, ' px')),
            ('Eccentricity', _formatNumber(record.eccentricity, '')),
            ('Star count', record.starCount?.toString() ?? '—'),
          ],
          colors: colors,
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _SectionHeader(label: 'ENVIRONMENT AT CAPTURE', colors: colors),
        const SizedBox(height: SkotiqTokens.spaceSm),
        if (env.isEmpty)
          Text(
            'No telemetry available at capture time.',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              fontStyle: FontStyle.italic,
              color: colors.textMuted,
            ),
          )
        else
          _MetricsGrid(
            rows: [
              (
                'Sky brightness',
                _formatNumber(env.skyBrightnessMag, ' mag/arcsec²')
              ),
              (
                'Cloud cover',
                _formatNumber(env.cloudCoverPercent, '%', digits: 0)
              ),
              ('Wind', _formatNumber(env.windKph, ' km/h', digits: 0)),
              ('Guide RMS', _formatNumber(env.guideRmsArcsec, '"')),
              ('Sensor temp', _formatNumber(env.sensorTempC, ' °C')),
            ],
            colors: colors,
          ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final SkotiqColors colors;
  const _SectionHeader({required this.label, required this.colors});
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: SkotiqTypography.fontSize10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: colors.textMuted,
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  final List<(String, String)> rows;
  final SkotiqColors colors;
  const _MetricsGrid({required this.rows, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: rows
          .map(
            (e) => TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    right: SkotiqTokens.spaceMd,
                    bottom: 4,
                  ),
                  child: Text(
                    e.$1,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    e.$2,
                    style: SkotiqTypography.withTabular(
                      SkotiqTypography.labelSm.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
          .toList(),
    );
  }
}

String _formatNumber(double? value, String suffix, {int digits = 2}) {
  if (value == null || value.isNaN || value.isInfinite) return '—';
  return '${value.toStringAsFixed(digits)}$suffix';
}

String _formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}';
}
