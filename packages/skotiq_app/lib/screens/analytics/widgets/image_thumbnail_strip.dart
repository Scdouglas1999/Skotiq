import 'dart:io';
import 'package:flutter/gestures.dart'
    show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        imagingBackendProvider,
        ImagingBackend,
        imagingRecordsRepositoryProvider,
        isRemoteModeProvider,
        DbCapturedImage,
        FramePhotometricCalibrationRow,
        FrameQualityAssessment,
        FrameQualityAssessmentService,
        FrameQualityLevel;

import '../../../utils/snackbar_helper.dart';
import '../analytics_screen.dart' show dbSessionImagesProvider;
import '../../../utils/filter_label.dart';
import 'frame_detail_dialog.dart';
import '../../../utils/image_decode_size.dart';
import '../../../widgets/frame_thumbnail_loader.dart';

part 'image_thumbnail_strip_parts/_chips.dart';
part 'image_thumbnail_strip_parts/_thumbnail.dart';

enum _QualityFilter {
  all,
  needsReview,
  poor,
}

/// Fixed height for the horizontal thumbnail rail (not a chart plot area).
const double kAnalyticsThumbnailRailHeight = 120;

/// Horizontal scrollable strip of image thumbnails.
///
/// Decorates each thumbnail with the existing quality badge plus a richer set
/// of science badges (plate-solve checkmark, zero-point chip when available)
/// and exposes an accept/reject context menu via long-press so users can flag
/// poor frames without losing them — implements the P3.4 "manual quality
/// gate, no auto-delete" pattern from the science gap list.
class ImageThumbnailStrip extends StatefulWidget {
  final List<DbCapturedImage> images;

  /// Overrides what a tap on a thumbnail does. When null the strip opens its
  /// own frame inspector — the rail is a gallery of the night's frames, and
  /// every caller in the app wants "show me this frame", so leaving the
  /// gesture inert unless a caller happened to supply a handler meant no
  /// caller ever did and clicking a thumbnail did nothing anywhere.
  final Function(DbCapturedImage)? onImageTap;

  /// Optional per-image calibration map (keyed by `image.id`). When supplied,
  /// the thumbnail strip renders a small ZP badge per frame and tints the
  /// border based on calibration status. Callers can omit this when they
  /// don't want to fetch calibrations for performance reasons.
  final Map<int, FramePhotometricCalibrationRow>? calibrationByImageId;

  const ImageThumbnailStrip({
    super.key,
    required this.images,
    this.onImageTap,
    this.calibrationByImageId,
  });

  @override
  State<ImageThumbnailStrip> createState() => _ImageThumbnailStripState();
}

class _ImageThumbnailStripState extends State<ImageThumbnailStrip> {
  _QualityFilter _qualityFilter = _QualityFilter.all;
  final ScrollController _railController = ScrollController();

  @override
  void dispose() {
    _railController.dispose();
    super.dispose();
  }

  /// A plain vertical mouse wheel over a horizontal rail does nothing in
  /// Flutter by default, so the page scrolled underneath and the trailing
  /// frames of a 200-frame night were only reachable with shift+wheel — which
  /// nothing on screen advertised. Translate vertical wheel deltas into
  /// horizontal scrolling; horizontal deltas are left to the Scrollable, which
  /// already consumes them (handling both would double-scroll).
  ///
  /// The move goes through the pointer-signal resolver rather than straight to
  /// `jumpTo`, because a bare `Listener` callback does not consume the event:
  /// the enclosing page Scrollable still saw the same notch and the rail and
  /// the page scrolled together, sliding the rail out from under the pointer.
  /// Registering here also loses on purpose when the rail's own Scrollable has
  /// already claimed the notch (shift+wheel), which otherwise moved the rail
  /// twice — once by the Scrollable and once by this handler.
  void _handleRailScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dx != 0 || event.scrollDelta.dy == 0) return;
    if (!_railController.hasClients) return;
    final position = _railController.position;
    if (position.maxScrollExtent <= 0) return;
    final target = (position.pixels + event.scrollDelta.dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // At either end the rail has nothing left to give, so the notch is left to
    // the page instead of being swallowed into a dead zone.
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) {
        if (!_railController.hasClients) return;
        _railController.jumpTo(target);
      },
    );
  }

  bool _matchesFilter(FrameQualityAssessment? assessment) {
    switch (_qualityFilter) {
      case _QualityFilter.all:
        return true;
      case _QualityFilter.needsReview:
        return assessment?.level == FrameQualityLevel.needsReview;
      case _QualityFilter.poor:
        return assessment?.level == FrameQualityLevel.poor;
    }
  }

  /// Whether the assessor has any measurement to judge this frame on.
  ///
  /// Calibration frames (and lights whose analysis has not run) carry none, and
  /// the assessor's score is a decrement-only walk from a 75 default — with
  /// nothing to decrement it returns "Good" for a frame nobody measured.
  static bool _hasQualityMeasurement(DbCapturedImage image) =>
      image.hfr != null ||
      image.starCount != null ||
      image.guidingRmsTotal != null ||
      image.qualityScore != null;

  String _filterLabel(_QualityFilter filter) {
    switch (filter) {
      case _QualityFilter.all:
        return 'All';
      case _QualityFilter.needsReview:
        return 'Needs Review';
      case _QualityFilter.poor:
        return 'Poor';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    const assessor = FrameQualityAssessmentService();
    // Only frames the assessor can actually judge are handed to it: its
    // advisory score starts at 75 and is only ever decremented by a metric, so
    // a frame with no HFR, no star count, no guiding RMS and no stored quality
    // score — every dark, flat and bias — would come back "Good, 75" without
    // having been measured, and be counted in the Good chip.
    final gradable =
        widget.images.where(_hasQualityMeasurement).toList(growable: false);
    final ungradedCount = widget.images.length - gradable.length;
    final assessments = assessor.assessBatch(gradable);
    final summary = assessor.summarize(assessments);
    final filteredImages = widget.images
        .where((image) => _matchesFilter(assessments[image.id]))
        .toList();

    if (widget.images.isEmpty) {
      return Container(
        height: kAnalyticsThumbnailRailHeight,
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        ),
        child: Center(
          child: Text(
            'No images captured in this session',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _SummaryChip(
              label: 'Good',
              value: summary.good,
              color: colors.success,
            ),
            _SummaryChip(
              label: 'Needs review',
              value: summary.needsReview,
              color: colors.warning,
            ),
            _SummaryChip(
              label: 'Poor',
              value: summary.poor,
              color: colors.error,
            ),
            if (ungradedCount > 0)
              _SummaryChip(
                label: 'Unrated',
                value: ungradedCount,
                color: colors.textMuted,
              ),
            _SummaryChip(
              label: 'Total',
              value: widget.images.length,
              color: colors.info,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _QualityFilter.values
              .map(
                (filter) => _QualityFilterChip(
                  label: _filterLabel(filter),
                  selected: _qualityFilter == filter,
                  onTap: () => setState(() => _qualityFilter = filter),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        SizedBox(
          // Thumbnail rail — fixed height (not chart-like). The list reserves
          // the bottom 10px of it for the always-visible scrollbar rather than
          // growing, so the loading and error placeholders that use this same
          // constant stay the same height as the loaded rail.
          height: kAnalyticsThumbnailRailHeight,
          child: filteredImages.isEmpty
              ? Container(
                  decoration: BoxDecoration(
                    color: colors.well,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    border: Border.all(color: colors.border),
                  ),
                  child: Center(
                    child: Text(
                      'No frames match "${_filterLabel(_qualityFilter)}"',
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textMuted),
                    ),
                  ),
                )
              : Listener(
                  onPointerSignal: _handleRailScroll,
                  child: Scrollbar(
                    controller: _railController,
                    // The rail is the only horizontal scroller on the page, and
                    // an overlay-only bar left "there are more frames" invisible
                    // until the user happened to drag it.
                    thumbVisibility: true,
                    child: ListView.builder(
                      controller: _railController,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(bottom: 10),
                      // Fixed-width thumbnails (100w + 8 right padding = 108).
                      itemExtent: 108,
                      itemCount: filteredImages.length,
                      itemBuilder: (context, index) {
                        final image = filteredImages[index];
                        return _ImageThumbnail(
                          image: image,
                          assessment: assessments[image.id],
                          calibration: widget.calibrationByImageId?[image.id],
                          onImageTap: widget.onImageTap,
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
