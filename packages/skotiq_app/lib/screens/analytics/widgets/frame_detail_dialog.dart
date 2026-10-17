import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        CoordinateParser,
        DbCapturedImage,
        FramePhotometricCalibrationRow,
        FrameQualityAssessment,
        imagingRecordsRepositoryProvider,
        isRemoteModeProvider;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/filter_label.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/frame_thumbnail_loader.dart';

/// Opens the single-frame inspector for [image].
///
/// The Analytics thumbnail rail is where an operator goes to look at the
/// night's frames, and a left click on one is the obvious way to ask "what is
/// this?". The rail's whole purpose — enlarge a frame, read what was recorded
/// with it, cull it — has to be reachable with that gesture, not only through
/// an unadvertised long-press / right-click menu.
///
/// Returns true when the frame's accepted flag changed, so the caller can
/// refresh whatever list it came from.
Future<bool> showFrameDetailDialog(
  BuildContext context, {
  required DbCapturedImage image,
  FrameQualityAssessment? assessment,
  FramePhotometricCalibrationRow? calibration,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => FrameDetailDialog(
      image: image,
      assessment: assessment,
      calibration: calibration,
    ),
  );
  return changed == true;
}

class FrameDetailDialog extends ConsumerStatefulWidget {
  final DbCapturedImage image;
  final FrameQualityAssessment? assessment;
  final FramePhotometricCalibrationRow? calibration;

  const FrameDetailDialog({
    super.key,
    required this.image,
    this.assessment,
    this.calibration,
  });

  @override
  ConsumerState<FrameDetailDialog> createState() => _FrameDetailDialogState();
}

class _FrameDetailDialogState extends ConsumerState<FrameDetailDialog> {
  late Future<FrameThumbnailPayload> _preview;
  late bool _isAccepted;
  bool _changed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _preview = loadFrameThumbnail(ref, widget.image);
    _isAccepted = widget.image.isAccepted;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final image = widget.image;

    return SkotiqDialog(
      title: image.fileName,
      icon: LucideIcons.image,
      width: 560,
      closeEnabled: !_busy,
      onClose: () => Navigator.of(context).pop(_changed),
      actions: [
        SkotiqButton(
          label: _isAccepted ? 'Flag as poor quality' : 'Restore as good',
          icon: _isAccepted ? LucideIcons.flag : LucideIcons.check,
          variant: ButtonVariant.secondary,
          onPressed: _busy ? null : _toggleAccepted,
        ),
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          onPressed: _busy ? null : () => Navigator.of(context).pop(_changed),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _preview$(colors),
          const SizedBox(height: SkotiqTokens.spaceLg),
          if (!_isAccepted) ...[
            SkotiqBanner(
              tone: BannerTone.warning,
              title: 'Rejected',
              message: image.rejectionReason?.trim().isNotEmpty == true
                  ? image.rejectionReason!
                  : 'This frame is excluded from stacks and session totals.',
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
          ],
          ..._metadataRows(colors),
        ],
      ),
    );
  }

  Widget _preview$(SkotiqColors colors) {
    return SizedBox(
      height: 240,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: SkotiqTokens.borderRadiusMd,
          border: Border.all(color: colors.border),
        ),
        child: FutureBuilder<FrameThumbnailPayload>(
          future: _preview,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            final payload =
                snapshot.data ?? const FrameThumbnailPayload(fileExists: false);
            if (payload.bytes != null && payload.bytes!.isNotEmpty) {
              return ClipRRect(
                borderRadius: SkotiqTokens.borderRadiusMd,
                child: Image.memory(payload.bytes!, fit: BoxFit.contain),
              );
            }
            if (payload.fileExists &&
                isDisplayableImagePath(widget.image.filePath) &&
                !ref.read(isRemoteModeProvider)) {
              return ClipRRect(
                borderRadius: SkotiqTokens.borderRadiusMd,
                child: Image.file(
                  File(widget.image.filePath),
                  fit: BoxFit.contain,
                ),
              );
            }
            // Say why there is no picture instead of leaving an empty box: the
            // usual cause is a FITS frame whose thumbnail was never cached, and
            // "no preview" reads as a broken dialog otherwise.
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(SkotiqIcons.imageOff,
                        size: 28, color: colors.textMuted),
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    Text(
                      payload.fileExists
                          ? 'No cached preview for this frame — the file is on '
                              'disk but has no thumbnail.'
                          : 'No preview available for this frame.',
                      textAlign: TextAlign.center,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _metadataRows(SkotiqColors colors) {
    final image = widget.image;
    final rows = <(String, String)>[
      (
        'Captured',
        DateFormat('EEE MMM d, yyyy · HH:mm:ss').format(
          image.capturedAt,
        )
      ),
      ('Frame type', image.frameType),
      ('Exposure', '${_trim(image.exposureDuration)} s'),
      ('Filter', filterLabel(image.filter)),
      if (image.gain != null) ('Gain', '${image.gain}'),
      if (image.offset != null) ('Offset', '${image.offset}'),
      ('Binning', '${image.binX}x${image.binY}'),
      if (image.sensorTemp != null)
        ('Sensor temperature', '${image.sensorTemp!.toStringAsFixed(1)} °C'),
      if (image.hfr != null) ('HFR', '${image.hfr!.toStringAsFixed(2)} px'),
      if (image.starCount != null) ('Stars detected', '${image.starCount}'),
      // Both scores, each named. The rail's tile shows the advisory number; the
      // database keeps the recorded one, and they differ by the review
      // penalties — so printing either as "the score" made the app disagree
      // with itself about one frame.
      if (image.qualityScore != null)
        (
          'Recorded quality score',
          '${image.qualityScore!.toStringAsFixed(1)} / 100'
        ),
      if (widget.assessment != null)
        (
          'Advisory score',
          '${widget.assessment!.advisoryScore.toStringAsFixed(0)} / 100'
        ),
      if (image.guidingRmsTotal != null)
        ('Guiding RMS', '${image.guidingRmsTotal!.toStringAsFixed(2)}"'),
      if (image.focuserPosition != null)
        ('Focuser position', '${image.focuserPosition} steps'),
      if (image.mountAltitude != null)
        ('Mount altitude', '${image.mountAltitude!.toStringAsFixed(1)}°'),
      // solvedRa is HOURS (the ASCOM convention this app carries internally),
      // so it is printed as h/m/s rather than as a bare decimal that reads as
      // degrees.
      if (image.isPlateSolved &&
          image.solvedRa != null &&
          image.solvedDec != null)
        (
          'Solved position',
          'RA ${CoordinateParser.formatRaHms(image.solvedRa!)}  '
              'Dec ${CoordinateParser.formatDecDms(image.solvedDec!)}'
        ),
      if (image.solvedPixelScale != null)
        (
          'Pixel scale',
          '${image.solvedPixelScale!.toStringAsFixed(2)}"/px',
        ),
      if (widget.calibration?.zeroPoint != null)
        (
          'Zero point',
          '${widget.calibration!.zeroPoint!.toStringAsFixed(3)} '
              '(${widget.calibration!.matchedStarCount} stars)'
        ),
      ('File', image.filePath),
    ];

    return [
      if (widget.assessment != null) ...[
        Text(
          widget.assessment!.summaryLine,
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          widget.assessment!.scoreExplanation,
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
      ],
      for (final (label, value) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 150,
                child: Text(
                  label,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
              ),
              Expanded(
                child: SelectableText(
                  value,
                  style: SkotiqTypography.labelSm
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  Future<void> _toggleAccepted() async {
    final next = !_isAccepted;
    setState(() => _busy = true);
    try {
      // Through the repository, not the local DAO: in remote mode the write
      // has to reach the host that owns the row.
      final repo = ref.read(imagingRecordsRepositoryProvider);
      if (next) {
        await repo.acceptImage(widget.image.id);
      } else {
        await repo.rejectImage(widget.image.id, 'Manual quality flag');
      }
      if (!mounted) return;
      setState(() {
        _isAccepted = next;
        _changed = true;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.showErrorSnackBar('Failed to update frame: $error');
    }
  }
}
