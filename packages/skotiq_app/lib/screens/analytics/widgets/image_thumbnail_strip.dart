import 'dart:io';
import 'package:flutter/gestures.dart'
    show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart'
    show ClockFormat, DurationFormat, QuantityFormat;
import 'package:skotiq_core/backend.dart' show ImagingBackend;
import 'package:skotiq_core/database.dart'
    show DbCapturedImage, FramePhotometricCalibrationRow;
import 'package:skotiq_core/errors.dart' show userFacingError;
import 'package:skotiq_core/providers.dart'
    show imagingBackendProvider, isRemoteModeProvider, SavedFrameRef;
import 'package:skotiq_core/services.dart'
    show
        imagingRecordsProvider,
        FrameQualityAssessment,
        FrameQualityAssessmentService,
        FrameQualityLevel;

import '../../../utils/snackbar_helper.dart';
import '../analytics_screen.dart' show dbSessionImagesProvider;
import '../../../utils/filter_label.dart';
import 'frame_detail_dialog.dart';
import '../../../utils/image_decode_size.dart';
import '../../../widgets/frame_exclusion_badge.dart';
import '../../../widgets/frame_thumbnail_loader.dart';
import '../../../widgets/saved_frame/saved_frame_viewer.dart';
import 'package:skotiq_core/models.dart';

part 'image_thumbnail_strip_parts/_chips.dart';
part 'image_thumbnail_strip_parts/_thumbnail.dart';

/// [image] as the saved-frame viewer names it; its Details open the frame
/// inspector, where the frame is flagged or restored.
SavedFrameEntry _viewerEntry(
  BuildContext context,
  DbCapturedImage image,
  FrameQualityAssessment? assessment,
  FramePhotometricCalibrationRow? calibration,
) {
  final hfr = image.hfr;
  final stars = image.starCount;
  return SavedFrameEntry(
    frame: SavedFrameRef(
      imageId: image.id,
      hostPath: image.filePath,
      capturedAt: image.capturedAt,
    ),
    title: image.fileName,
    time: ClockFormat.hms(image.capturedAt.toLocal()),
    status: [
      if (!image.isAccepted)
        'Rejected'
      else if (assessment != null)
        switch (assessment.level) {
          FrameQualityLevel.good => 'Good',
          FrameQualityLevel.needsReview => 'Needs review',
          FrameQualityLevel.poor => 'Poor',
        },
      if (hfr != null) 'HFR ${hfr.toStringAsFixed(2)}',
      if (stars != null) '$stars stars',
    ].join(' · '),
    accepted: image.isAccepted,
    onDetails: () async {
      final changed = await showFrameDetailDialog(
        context,
        image: image,
        assessment: assessment,
        calibration: calibration,
      );
      // Flagging from the inspector has to reach the strip, the stat strip
      // and the charts, which all read the same polled provider.
      if (changed && context.mounted) {
        ProviderScope.containerOf(
          context,
          listen: false,
        ).invalidate(dbSessionImagesProvider);
      }
    },
  );
}

enum _QualityFilter { all, needsReview, poor }

/// A frame tile's height: a picture tall enough that the badges along its
/// top edge, the glyph in its middle and the badges along its bottom edge
/// each have their own band, over three lines of caption.
const double _kThumbnailHeight = 142;

/// Room under the rail's tiles for its scrollbar.
const double _kRailScrollbarInset = 10;

/// Fixed height for the horizontal thumbnail rail (not a chart plot area).
const double kAnalyticsThumbnailRailHeight =
    _kThumbnailHeight + _kRailScrollbarInset;

/// A tile's width: room for the verdict badge and the HFR badge side by side
/// without either being cut off.
const double _kThumbnailWidth = 132;
const double _kThumbnailGap = SkotiqTokens.spaceSm;

/// The widest a grid tile grows before another column is added. A phone
/// then shows two columns at least as wide as a rail tile.
const double _kGridTileMaxWidth = 180;

/// The frames of a session as graded tiles: a horizontal rail, or with
/// [ImageThumbnailStrip.grid] a grid that fills the height it is given.
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

  /// Lays the tiles out as a wrapping grid that scrolls vertically. The
  /// widget must then be given a bounded height.
  final bool grid;

  const ImageThumbnailStrip({
    super.key,
    required this.images,
    this.onImageTap,
    this.calibrationByImageId,
    this.grid = false,
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
        return 'Needs review';
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
        decoration: SkotiqDecorations.well(colors),
        alignment: Alignment.center,
        child: Text(
          'No images captured in this session',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      );
    }

    SavedFrameEntry entry(DbCapturedImage image) => _viewerEntry(
          context,
          image,
          assessments[image.id],
          widget.calibrationByImageId?[image.id],
        );
    Widget tile(DbCapturedImage image) => _ImageThumbnail(
          image: image,
          assessment: assessments[image.id],
          calibration: widget.calibrationByImageId?[image.id],
          onImageTap: widget.onImageTap,
          onOpen: () => SavedFrameViewer.show(
            context,
            frames: [for (final shown in filteredImages) entry(shown)],
            initialIndex: filteredImages.indexOf(image),
          ),
        );
    final noMatch = Container(
      height: _kThumbnailHeight,
      decoration: SkotiqDecorations.well(colors),
      alignment: Alignment.center,
      child: Text(
        'No frames match "${_filterLabel(_qualityFilter)}"',
        style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
      ),
    );
    final Widget tiles;
    if (filteredImages.isEmpty) {
      tiles = widget.grid
          ? Align(alignment: Alignment.topCenter, child: noMatch)
          : noMatch;
    } else if (widget.grid) {
      tiles = GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: _kGridTileMaxWidth,
          mainAxisExtent: _kThumbnailHeight,
          crossAxisSpacing: _kThumbnailGap,
          mainAxisSpacing: _kThumbnailGap,
        ),
        itemCount: filteredImages.length,
        itemBuilder: (context, index) => tile(filteredImages[index]),
      );
    } else {
      tiles = Listener(
        onPointerSignal: _handleRailScroll,
        child: Scrollbar(
          controller: _railController,
          thumbVisibility: true,
          child: ListView.builder(
            controller: _railController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(bottom: _kRailScrollbarInset),
            itemExtent: _kThumbnailWidth + _kThumbnailGap,
            itemCount: filteredImages.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(right: _kThumbnailGap),
              child: tile(filteredImages[index]),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: SkotiqTokens.spaceSm,
          runSpacing: SkotiqTokens.spaceSm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedControl(
              segments: [
                for (final filter in _QualityFilter.values)
                  _filterLabel(filter),
              ],
              selectedIndex: _qualityFilter.index,
              onSelected: (index) => setState(
                () => _qualityFilter = _QualityFilter.values[index],
              ),
              semanticLabel: 'Frames shown',
            ),
            SkotiqChip(label: 'Good ${summary.good}', tone: ChipTone.success),
            SkotiqChip(
              label: 'Needs review ${summary.needsReview}',
              tone: ChipTone.warning,
            ),
            SkotiqChip(label: 'Poor ${summary.poor}', tone: ChipTone.error),
            if (ungradedCount > 0) SkotiqChip(label: 'Unrated $ungradedCount'),
            SkotiqChip(label: 'Total ${widget.images.length}'),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        if (widget.grid)
          Expanded(child: tiles)
        else
          SizedBox(height: kAnalyticsThumbnailRailHeight, child: tiles),
      ],
    );
  }
}
