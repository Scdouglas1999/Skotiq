// The individual thumbnail widget and its state.
part of '../image_thumbnail_strip.dart';

class _ImageThumbnail extends ConsumerStatefulWidget {
  final DbCapturedImage image;
  final FrameQualityAssessment? assessment;
  final FramePhotometricCalibrationRow? calibration;
  final Function(DbCapturedImage)? onImageTap;

  const _ImageThumbnail({
    required this.image,
    this.assessment,
    this.calibration,
    this.onImageTap,
  });

  @override
  ConsumerState<_ImageThumbnail> createState() => _ImageThumbnailState();
}

class _ImageThumbnailState extends ConsumerState<_ImageThumbnail> {
  late Future<FrameThumbnailPayload> _thumbnailFuture;
  ProviderSubscription<ImagingBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _thumbnailFuture = loadFrameThumbnail(ref, widget.image);
    _backendSubscription = ref.listenManual<ImagingBackend>(
      imagingBackendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        setState(() {
          _thumbnailFuture = loadFrameThumbnail(ref, widget.image);
        });
      },
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.id != widget.image.id ||
        oldWidget.image.filePath != widget.image.filePath) {
      _thumbnailFuture = loadFrameThumbnail(ref, widget.image);
    }
  }

  /// The rail tile's top corners. Both preview rungs share it so they cannot
  /// drift apart.
  static Widget _railClip(Widget child) => ClipRRect(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(SkotiqTokens.radiusLg),
          topRight: Radius.circular(SkotiqTokens.radiusLg),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    final qualityColor = _getQualityColor(colors);
    final qualityBorderColor =
        !widget.image.isAccepted ? colors.error : qualityColor;
    final qualityBorderWidth = widget.image.isAccepted &&
            widget.assessment != null &&
            widget.assessment!.level == FrameQualityLevel.good
        ? 1.0
        : 2.0;

    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: Semantics(
          button: true,
          enabled: true,
          child: InkWell(
            onTap: _handleTap,
            onLongPress: () => _showFrameMenu(context),
            onSecondaryTap: () => _showFrameMenu(context),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            child: Container(
              width: 100,
              decoration: BoxDecoration(
                color: colors.well,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
                border: Border.all(
                  color: qualityBorderColor,
                  width: qualityBorderWidth,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(SkotiqTokens.radiusLg),
                          topRight: Radius.circular(SkotiqTokens.radiusLg),
                        ),
                      ),
                      child: Stack(
                        children: [
                          Center(
                            child: FutureBuilder<FrameThumbnailPayload>(
                              future: _thumbnailFuture,
                              builder: (context, snapshot) {
                                if (snapshot.connectionState ==
                                        ConnectionState.waiting &&
                                    !snapshot.hasData) {
                                  return const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: SkotiqMark(size: 18),
                                  );
                                }

                                final payload = snapshot.data ??
                                    const FrameThumbnailPayload(
                                        fileExists: false);

                                if (payload.bytes != null &&
                                    payload.bytes!.isNotEmpty) {
                                  // Decoded at cell width, not at the 512 px
                                  // the backend encoded: this rail can hold a
                                  // whole night of frames.
                                  return _railClip(
                                    LayoutBuilder(
                                      builder: (context, constraints) =>
                                          Image.memory(
                                        payload.bytes!,
                                        fit: BoxFit.cover,
                                        width: double.infinity,
                                        height: double.infinity,
                                        cacheWidth: thumbnailDecodeWidth(
                                          context,
                                          constraints.maxWidth,
                                        ),
                                        errorBuilder: (_, __, ___) => Icon(
                                          SkotiqIcons.imageOff,
                                          size: 32,
                                          color: colors.textMuted,
                                        ),
                                      ),
                                    ),
                                  );
                                }

                                if (payload.fileExists &&
                                    isDisplayableImagePath(
                                        widget.image.filePath) &&
                                    !isRemoteMode) {
                                  return _railClip(
                                    LayoutBuilder(
                                      builder: (context, constraints) =>
                                          Image.file(
                                        File(widget.image.filePath),
                                        fit: BoxFit.cover,
                                        width: double.infinity,
                                        height: double.infinity,
                                        cacheWidth: thumbnailDecodeWidth(
                                          context,
                                          constraints.maxWidth,
                                        ),
                                        errorBuilder: (_, __, ___) => Icon(
                                          SkotiqIcons.image,
                                          size: 32,
                                          color: colors.textMuted,
                                        ),
                                      ),
                                    ),
                                  );
                                }

                                if (payload.fileExists) {
                                  return Icon(
                                    SkotiqIcons.image,
                                    size: 32,
                                    color: colors.textMuted,
                                  );
                                }

                                if (payload.errorMessage != null) {
                                  return Tooltip(
                                    message: payload.errorMessage!,
                                    child: Icon(
                                      SkotiqIcons.error,
                                      size: 32,
                                      color: colors.error,
                                    ),
                                  );
                                }

                                return Icon(
                                  SkotiqIcons.imageOff,
                                  size: 32,
                                  color: colors.textMuted,
                                );
                              },
                            ),
                          ),
                          // Quality badge (GOOD / NEEDS REVIEW / POOR) is added
                          // AFTER the thumbnail so it paints ON TOP of it: as
                          // the Stack's first child it is covered by every
                          // thumbnail that loads (Image.memory, BoxFit.cover,
                          // infinite width/height).
                          //
                          // An unmeasured frame gets an explicit UNRATED chip
                          // rather than a missing badge, so "no grade" reads as a
                          // statement instead of as a rendering gap.
                          Positioned(
                            top: 4,
                            left: 4,
                            child: Tooltip(
                              message: _qualityTooltip(),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: qualityColor.withValues(alpha: 0.92),
                                  borderRadius: BorderRadius.circular(
                                      SkotiqTokens.radiusInline4),
                                ),
                                child: Text(
                                  widget.assessment?.label.toUpperCase() ??
                                      'UNRATED',
                                  style: SkotiqTypography.caption.copyWith(
                                    color: SkotiqColors.dark.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (widget.image.hfr != null)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _getHfrColor(widget.image.hfr!, colors)
                                      .withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(
                                      SkotiqTokens.radiusInline4),
                                ),
                                child: Text(
                                  widget.image.hfr!.toStringAsFixed(1),
                                  style: SkotiqTypography.caption.copyWith(
                                    color: SkotiqColors.dark.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          // P2.3 science badges: small solve checkmark + optional
                          // ZP chip. Sit bottom-right so they don't fight the HFR
                          // and quality badges, and only appear when there is
                          // something meaningful to report.
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.calibration?.zeroPoint != null)
                                  _ScienceBadge(
                                    tooltip:
                                        'Zero-point ${widget.calibration!.zeroPoint!.toStringAsFixed(2)} · '
                                        '${widget.calibration!.matchedStarCount} stars',
                                    color: colors.info,
                                    label:
                                        'ZP ${widget.calibration!.zeroPoint!.toStringAsFixed(1)}',
                                  ),
                                if (widget.calibration?.zeroPoint != null &&
                                    widget.image.isPlateSolved)
                                  const SizedBox(width: 3),
                                if (widget.image.isPlateSolved)
                                  _ScienceBadge(
                                    tooltip: 'Plate solved',
                                    color: colors.success,
                                    icon: LucideIcons.crosshair,
                                  ),
                              ],
                            ),
                          ),
                          if (!widget.image.isAccepted &&
                              frameExclusionKindOf(
                                    widget.image.rejectionReason,
                                  ) !=
                                  null)
                            Positioned(
                              bottom: 4,
                              left: 4,
                              child: FrameExclusionBadge.forReason(
                                widget.image.rejectionReason,
                              ),
                            )
                          else if (!widget.image.isAccepted)
                            Positioned(
                              bottom: 4,
                              left: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: colors.error,
                                  borderRadius: BorderRadius.circular(
                                      SkotiqTokens.radiusInline4),
                                ),
                                child: Text(
                                  'REJECTED',
                                  style: SkotiqTypography.caption.copyWith(
                                      color: colors.background,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          filterLabel(widget.image.filter),
                          style: SkotiqTypography.caption.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${widget.image.exposureDuration.toInt()}s',
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.textSecondary),
                        ),
                        if (widget.assessment != null)
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  // "NN score" collided with the frame's recorded
                                  // quality_score, which is a different number for
                                  // the same frame. Name the one on the tile.
                                  'Advisory ${widget.assessment!.advisoryScore.toStringAsFixed(0)}',
                                  style: SkotiqTypography.caption.copyWith(
                                      color: qualityColor,
                                      fontWeight: FontWeight.w600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (widget.assessment!.needsReview &&
                                  widget.assessment!.reasons.isNotEmpty)
                                Tooltip(
                                  message:
                                      widget.assessment!.reasons.join('\n'),
                                  child: Icon(
                                    SkotiqIcons.info,
                                    size: 10,
                                    color: qualityColor,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          )),
    );
  }

  /// Opens the frame inspector, unless the caller supplied its own handler.
  Future<void> _handleTap() async {
    final override = widget.onImageTap;
    if (override != null) {
      override(widget.image);
      return;
    }
    final changed = await showFrameDetailDialog(
      context,
      image: widget.image,
      assessment: widget.assessment,
      calibration: widget.calibration,
    );
    // Accepting/rejecting from the inspector has to reach the rail, the stat
    // strip and the four charts, all of which read the same polled provider.
    if (changed && mounted) ref.invalidate(dbSessionImagesProvider);
  }

  String _qualityTooltip() {
    if (widget.assessment == null) {
      return 'Not rated — this frame has no HFR, star count, guiding RMS or '
          'stored quality score to judge';
    }
    return '${widget.assessment!.summaryLine}\n'
        '${widget.assessment!.scoreExplanation}';
  }

  Color _getQualityColor(SkotiqColors colors) {
    if (!widget.image.isAccepted) return colors.error;
    final value = widget.assessment;
    // Unrated frames get a neutral chip, not a quality colour.
    if (value == null) return colors.textMuted;

    switch (value.level) {
      case FrameQualityLevel.good:
        return colors.success;
      case FrameQualityLevel.needsReview:
        return colors.warning;
      case FrameQualityLevel.poor:
        return colors.error;
    }
  }

  Color _getHfrColor(double hfr, SkotiqColors colors) {
    if (hfr < 2.0) {
      return colors.success;
    } else if (hfr < 2.5) {
      return colors.info;
    } else if (hfr < 3.5) {
      return colors.warning;
    } else {
      return colors.error;
    }
  }

  Future<void> _showFrameMenu(BuildContext context) async {
    final colors = SkotiqColors.of(context);
    final isAccepted = widget.image.isAccepted;
    final backend = ref.read(imagingBackendProvider);
    final action = await showMenu<_FrameMenuAction>(
      context: context,
      position: _menuPosition(context),
      color: colors.surface,
      items: <PopupMenuEntry<_FrameMenuAction>>[
        PopupMenuItem(
          value: isAccepted ? _FrameMenuAction.reject : _FrameMenuAction.accept,
          child: Row(
            children: [
              Icon(
                isAccepted ? LucideIcons.flag : LucideIcons.check,
                size: 14,
                color: isAccepted ? colors.warning : colors.success,
              ),
              const SizedBox(width: 8),
              Text(
                isAccepted ? 'Flag as poor quality' : 'Restore as good',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ),
        if (widget.calibration != null)
          PopupMenuItem(
            value: _FrameMenuAction.info,
            child: Row(
              children: [
                Icon(LucideIcons.info, size: 14, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  'Show calibration details',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textPrimary),
                ),
              ],
            ),
          ),
      ],
    );
    if (!mounted || !context.mounted || action == null) return;
    if (!identical(ref.read(imagingBackendProvider), backend)) {
      context.showErrorSnackBar(
        'Connected rig changed; the frame was not modified',
      );
      return;
    }
    switch (action) {
      case _FrameMenuAction.accept:
        await _setAccepted(true);
        break;
      case _FrameMenuAction.reject:
        await _setAccepted(false);
        break;
      case _FrameMenuAction.info:
        if (!context.mounted) return;
        _showCalibrationDetails(context);
        break;
    }
  }

  /// Route accept/reject through the imaging-records repository so the write
  /// reaches the remote host in NetworkBackend mode (the local DAO would only
  /// mutate an empty companion DB), then refresh the polled session images.
  Future<void> _setAccepted(bool accepted) async {
    try {
      final repo = ref.read(imagingRecordsRepositoryProvider);
      if (accepted) {
        await repo.acceptImage(widget.image.id);
      } else {
        await repo.rejectImage(widget.image.id, 'Manual quality flag');
      }
      if (!mounted) return;
      ref.invalidate(dbSessionImagesProvider);
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Failed to update frame: $e');
    }
  }

  /// A small square at the thumbnail's top-left, rather than the thumbnail's
  /// own bounds: a frame tile is wide, and anchoring on the whole tile would
  /// let the menu right-align off the far edge of it.
  static const Size _menuAnchorSize = Size(40, 40);

  RelativeRect _menuPosition(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    return menuPositionFromRect(
      context,
      box.localToGlobal(Offset.zero) & _menuAnchorSize,
    );
  }

  void _showCalibrationDetails(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final c = widget.calibration;
    if (c == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text('Frame ${widget.image.fileName}',
            style: SkotiqTypography.sectionTitle
                .copyWith(color: colors.textPrimary)),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 420,
            designMaxHeight: 360,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DetailRow('Calibrated', c.isCalibrated ? 'Yes' : 'No', colors),
              _DetailRow(
                'Zero point',
                c.zeroPoint == null
                    ? kReadoutUnknown
                    : c.zeroPoint!.toStringAsFixed(3),
                colors,
              ),
              _DetailRow(
                  'Matched stars', c.matchedStarCount.toString(), colors),
              _DetailRow(
                'Fit RMS',
                '${c.calibrationRms.toStringAsFixed(3)} mag',
                colors,
              ),
              _DetailRow('Catalog', c.catalogSource, colors),
              _DetailRow('Solver', c.solverId, colors),
              if (c.limitingMag5Sigma != null)
                _DetailRow(
                  'Lim mag (5Ïƒ)',
                  c.limitingMag5Sigma!.toStringAsFixed(2),
                  colors,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
