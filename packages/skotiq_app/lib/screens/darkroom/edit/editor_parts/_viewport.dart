part of '../darkroom_editor.dart';

/// Screen pixels per MASTER pixel in the Darkroom viewport.
///
/// The number is NOT the viewer's own zoom: the preview is rendered from a
/// pyramid level, so a viewer scale of 1.0 over a level-2 preview draws one
/// screen pixel per FOUR master pixels. Every readout that says a percentage
/// must say it about the master, or it describes a picture that is not the
/// operator's data.
///
/// Defaults to 1.0 so a reader that runs before the first render has laid out
/// sees "unscaled" rather than zero. Published by [_DarkroomViewport], the only
/// widget that knows both the viewport and the render's level.
final darkroomDisplayScaleProvider = StateProvider<double>((ref) => 1.0);

/// Widest zoom the Darkroom viewport allows.
///
/// Higher than the viewer's own default because 1:1 on a master pixel means a
/// viewer scale of `1 / scaleFromMaster`: a level-4 preview needs 16× before a
/// screen pixel is a master pixel.
const double kDarkroomMaxViewerScale = 32.0;

/// Narrowest zoom the Darkroom viewport allows.
const double kDarkroomMinViewerScale = 0.05;

/// Step one press of the zoom buttons takes.
const double kDarkroomZoomStep = 1.25;

/// What the picture on screen IS, in words.
///
/// Every fact is read off the render being painted — its own dimensions, the
/// domain its samples are in, the pyramid level it came from — and joined to
/// the branch and the master those pixels belong to. Nothing is read off the
/// stack as it stands: a render that fails leaves the previous picture up and
/// clears its step reports, so a label that counted the steps now in the editor
/// would describe a render that never happened. When the pixels are not the
/// current stack's, the label says so in the same terms the strip under the
/// canvas does.
///
/// [name] overrides the branch this render belongs to, which is what the
/// compare panes pass: a pane's own strip names the SIDE and the branch, and
/// the reader of a two-pane view needs to know which of the two a picture is.
String darkroomPictureLabel(
  DarkroomState state,
  DarkroomPreviewImage preview, {
  String? name,
}) {
  final stage = switch (preview.encoding.sourceDomain) {
    'linear' => 'still-linear pixels',
    'stretched' => 'stretched pixels',
    null => 'pixels whose stage the engine did not name',
    final String named => 'pixels the engine called "$named"',
  };
  final level = preview.level;
  final from = level == null ? '' : ', rendered from pyramid level $level';
  final String freshness;
  if (state.rendering) {
    freshness = ' A newer render is still running, so these are the previous '
        'render\'s pixels.';
  } else if (state.renderError != null) {
    freshness = ' This is the last render that finished, not the stack as it '
        'stands.';
  } else {
    freshness = '';
  }
  return 'Rendered draft of ${name ?? state.recipeName} over '
      '${p.basename(state.baseMasterPath)}: ${preview.width}×'
      '${preview.height} ${preview.isColor ? 'colour' : 'monochrome'} '
      '$stage$from.$freshness';
}

/// The view transform, and every operation the zoom controls perform on it.
///
/// Owned by the widget that lays the picture out — the single-recipe viewport
/// and the compare view each own one — because fit and 1:1 both need the box
/// the picture is laid out in, and because a new render must not throw away the
/// zoom and pan the operator set on the previous one.
///
/// Compare hands its ONE instance to both panes, which is what keeps the two
/// sides locked; the controls therefore drive both from a single row.
class _DarkroomZoom {
  final TransformationController controller = TransformationController();

  /// The box the viewer is laid out in, measured in the last layout.
  Size box = Size.zero;

  /// The viewer's own scale: screen pixels per RENDERED pixel.
  ///
  /// Read off the X and Y columns, which are the two the picture is laid out
  /// on. `Matrix4.getMaxScaleOnAxis` takes the maximum over X, Y **and Z**, and
  /// every write below leaves Z at 1 — so it answered exactly 1.0 for every
  /// view narrower than 1:1 and the readout said "100% of master" over a
  /// picture fitted at half that. It pinned more than the words: the zoom floor
  /// clamped against a scale that was not the view's, and `1:1` over a level-0
  /// render asked for the scale it was already told it had and returned having
  /// done nothing.
  double get viewerScale {
    final m = controller.value;
    final x = math.sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
    final y = math.sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]);
    return x > y ? x : y;
  }

  /// Screen pixels per MASTER pixel for [preview], or null when the render did
  /// not state the level it answered at.
  double? masterScale(DarkroomPreviewImage? preview) {
    final scale = preview?.scaleFromMaster;
    if (scale == null) return null;
    return viewerScale * scale;
  }

  void fit(DarkroomPreviewImage? preview) {
    if (preview == null) return;
    if (box.width <= 0 || box.height <= 0) return;
    if (preview.width <= 0 || preview.height <= 0) return;
    final scaleX = box.width / preview.width;
    final scaleY = box.height / preview.height;
    final fit = scaleX < scaleY ? scaleX : scaleY;
    controller.value = Matrix4.identity()
      ..translateByDouble(
        (box.width - preview.width * fit) / 2,
        (box.height - preview.height * fit) / 2,
        0,
        1.0,
      )
      ..scaleByDouble(fit, fit, 1.0, 1.0);
  }

  /// One screen pixel per MASTER pixel, as close as the zoom ceiling allows.
  ///
  /// A coarse pyramid level cannot reach 1:1 inside the ceiling; the readout
  /// then shows the scale that was actually reached, so the picture is never
  /// labelled 100% when it is not.
  void oneToOne(DarkroomPreviewImage? preview) {
    final scale = preview?.scaleFromMaster;
    if (scale == null) return;
    scaleAboutCentre(1.0 / scale);
  }

  void zoomBy(double factor) => scaleAboutCentre(viewerScale * factor);

  void scaleAboutCentre(double target) {
    if (box.width <= 0 || box.height <= 0) return;
    final current = viewerScale;
    if (current <= 0) return;
    final clamped = target.clamp(
      kDarkroomMinViewerScale,
      kDarkroomMaxViewerScale,
    );
    if (clamped == current) return;
    final factor = clamped / current;
    final focalX = box.width / 2;
    final focalY = box.height / 2;
    final matrix = Matrix4.identity()
      ..translateByDouble(focalX, focalY, 0, 1.0)
      ..scaleByDouble(factor, factor, 1.0, 1.0)
      ..translateByDouble(-focalX, -focalY, 0, 1.0);
    controller.value = matrix * controller.value;
  }

  void dispose() => controller.dispose();
}

/// Why a render that landed still cannot be put at one screen pixel per master
/// pixel.
const String kDarkroomOneToOneNeedsLevel =
    'this render did not say which pyramid level it answered at, so one screen '
    'pixel per master pixel cannot be worked out';

/// Why the single-recipe viewport has no pixels to zoom, in the same terms the
/// canvas below states it.
///
/// Only asked when there is no preview, and the order matches the canvas's own
/// branches so the row and the picture never give two accounts of one state.
String _darkroomNoRenderReason(DarkroomState state) {
  if (state.rendering) {
    return 'the first render over this master is still running';
  }
  if (state.renderError != null) {
    return 'the render did not finish, so there are no pixels to zoom';
  }
  if (state.cancelledPhase != null) {
    return 'the render was stopped, so there are no pixels to zoom';
  }
  return 'nothing has rendered over this master yet';
}

/// The row of zoom controls above the picture, with the readout that says what
/// its percentage is about.
///
/// Shared by the single-recipe viewport and the A/B compare, which used to
/// build its own pane chrome and so shipped without any of this: compare had no
/// zoom control, no percentage, and no way to land on 1:1 at all — the one
/// magnification a noise comparison is for — with the mouse wheel as the only
/// way to change the view and nothing for a keyboard or assistive tech.
///
/// **A disabled control here states why.** All four went dead together on a
/// null preview and published nothing but the dimming: in compare that left
/// four dead buttons over a picture the wheel still zoomed, and in the single
/// viewport it left them dead with the reason only in the canvas below. The
/// refusal now rides on the accessible NAME through [unavailableControlName],
/// the seam the Compare button and the master library's Darkroom button already
/// use, because the Linux AT-SPI bridge folds neither `tooltip` nor `hint` into
/// the name.
class _DarkroomZoomControls extends StatelessWidget {
  final _DarkroomZoom zoom;

  /// The render these controls operate over and the readout describes.
  ///
  /// Not necessarily the enclosing view's own render: compare hands over
  /// whichever of its two panes has pixels, because one transform moves both
  /// and a pane that failed to render cannot take the zoom away from a pane
  /// that has a picture.
  final DarkroomPreviewImage? preview;

  /// Why there is nothing to zoom. Read only when [preview] is null, and
  /// required so no caller can disable this row without saying why.
  final String noRenderReason;

  /// The side [preview] came from, when the enclosing view holds more than one
  /// and the numbers are not about the side it would otherwise be showing.
  /// Null in the single-recipe viewport, which has one render only.
  final String? measuredOn;

  /// Controls the enclosing view adds to the same row, ahead of the zoom
  /// controls: one bordered row rather than two stacked ones.
  final List<Widget> leading;

  /// Tags the enclosing view adds after the readout.
  final List<Widget> trailing;

  /// Draw as a glass panel floating OVER the picture rather than as a bordered
  /// bar above it.
  ///
  /// 02's first rule gives the image the largest uninterrupted area it can,
  /// with the controls floating over it; 05 §14 allows glass only inside an
  /// image stack. The single-recipe viewport is that stack. The A/B compare is
  /// not: it lays out two panes, and one glass element per pane per corner
  /// would blow the four-element ceiling — so compare keeps the bar.
  final bool overImage;

  const _DarkroomZoomControls({
    required this.zoom,
    required this.preview,
    required this.noRenderReason,
    this.measuredOn,
    this.leading = const [],
    this.trailing = const [],
    this.overImage = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final preview = this.preview;
    final masterScale = zoom.masterScale(preview);
    // Null means live. One reason for the three controls that only need
    // pixels; 1:1 needs the level as well, and refuses in its own words when
    // the pixels are there and the level is not.
    final String? dead = preview == null ? noRenderReason : null;
    final String? oneToOneDead = preview == null
        ? noRenderReason
        : preview.scaleFromMaster == null
            ? kDarkroomOneToOneNeedsLevel
            : null;
    final on = measuredOn == null ? '' : ', measured on pane $measuredOn';
    final controls = Wrap(
      spacing: SkotiqTokens.spaceXs,
      runSpacing: SkotiqTokens.spaceXs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...leading,
        _iconControl(
          SkotiqIcons.remove,
          'Zoom out',
          dead,
          () => zoom.zoomBy(1 / kDarkroomZoomStep),
        ),
        _iconControl(
          SkotiqIcons.add,
          'Zoom in',
          dead,
          () => zoom.zoomBy(kDarkroomZoomStep),
        ),
        _labelControl('Fit', dead, () => zoom.fit(preview)),
        _labelControl('1:1', oneToOneDead, () => zoom.oneToOne(preview)),
        Semantics(
          // Its own node: with the annotation merged into whatever encloses
          // it, the percentage joined the row's other words into one run and
          // stopped being a readout anybody could find.
          container: true,
          label: switch ((dead, masterScale)) {
            // No pixels: the readout says the same thing the four controls
            // say, rather than "unknown" over a row whose refusal is a
            // different sentence.
            (final String reason, _) => 'Zoom is unavailable — $reason',
            (null, null) => 'Zoom relative to the master is unknown',
            (null, final double scale) =>
              'Zoom ${(scale * 100).round()} percent of the master$on',
          },
          child: ExcludeSemantics(
            child: Text(
              masterScale == null
                  ? '—'
                  : '${(masterScale * 100).round()}% of master'
                      '${measuredOn == null ? '' : ' · $measuredOn'}',
              style: SkotiqTypography.monoSm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ),
        ...trailing,
      ],
    );

    // Over the picture the controls are the only chrome, so the zoom percentage
    // is a Readout rather than a line of mono text beside four buttons.
    if (overImage) return Glass(child: controls);

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceXs,
      ),
      child: controls,
    );
  }

  /// One icon control, disabled with [reason] in its name when it has one.
  Widget _iconControl(
    IconData icon,
    String label,
    String? reason,
    VoidCallback onPressed,
  ) {
    return AccessibleIconButton(
      icon: icon,
      label: reason == null ? label : unavailableControlName(label, reason),
      // The pointer's copy of the same sentence; null falls back to the label,
      // which is what a live control wants.
      tooltip: reason,
      size: SkotiqTokens.iconSm,
      onPressed: reason == null ? onPressed : null,
    );
  }

  /// One labelled control, disabled with [reason] in its name when it has one.
  ///
  /// The refusal cannot go in [SkotiqButton.label] — that string is painted
  /// — so the disabled branch publishes its own node and excludes the button's,
  /// the shape `_branch_bar.dart` uses for the Compare button.
  Widget _labelControl(String label, String? reason, VoidCallback onPressed) {
    final button = SkotiqButton(
      label: label,
      variant: ButtonVariant.secondary,
      size: ButtonSize.small,
      onPressed: reason == null ? onPressed : null,
    );
    if (reason == null) return button;
    return Tooltip(
      message: reason,
      child: Semantics(
        container: true,
        button: true,
        enabled: false,
        label: unavailableControlName(label, reason),
        excludeSemantics: true,
        child: button,
      ),
    );
  }
}

/// The rendered image, and the controls that move the view over it.
class _DarkroomViewport extends ConsumerStatefulWidget {
  final DarkroomState state;

  /// Re-check and re-render the committed stack now.
  final Future<void> Function() onRerender;

  const _DarkroomViewport({required this.state, required this.onRerender});

  @override
  ConsumerState<_DarkroomViewport> createState() => _DarkroomViewportState();
}

class _DarkroomViewportState extends ConsumerState<_DarkroomViewport> {
  /// Owned here, not by [_DarkroomImageSurface], because the fit / 1:1 / zoom
  /// controls drive it — and because a new render must not throw away the zoom
  /// and pan the operator set on the previous one.
  final _DarkroomZoom _zoom = _DarkroomZoom();

  TransformationController get _transform => _zoom.controller;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _zoom.dispose();
    super.dispose();
  }

  /// Repaint the readout. The transform changes on wheel zoom, on drag-pan and
  /// on pinch, and only some of those pass through this widget, so the readout
  /// listens to the controller itself.
  ///
  /// One of those changes arrives from the frame after a layout: the surface
  /// measures its container in a layout callback and writes the initial fit to
  /// this controller. Marking this widget dirty from inside layout asks for a
  /// build during a layout that is already running — the request lands against
  /// a render object whose layout is in flight, is dropped when that layout
  /// finishes, and takes the enclosing panel layout's build scope down with it:
  /// every later rebuild of the viewport, the recipe panel and the history
  /// stack is skipped until a window resize forces a real relayout. Debug
  /// builds catch it on an assert inside the framework's own scheduler; release
  /// builds strip that assert, which is why the editor froze only when shipped.
  /// Repainting on the next frame is the same readout one frame later, and it
  /// is the only moment at which asking for a build is legal.
  void _onTransformChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  /// Hand the measured scale to readers outside this subtree.
  ///
  /// Deferred to a post-frame callback because it is computed inside `build`
  /// and mutating a provider during a build is illegal. The equality guard
  /// makes this converge in one extra frame rather than looping.
  void _publishDisplayScale(double scale) {
    if (ref.read(darkroomDisplayScaleProvider) == scale) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(darkroomDisplayScaleProvider.notifier).state = scale;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final state = widget.state;
    final masterScale = _zoom.masterScale(state.preview);
    if (masterScale != null) _publishDisplayScale(masterScale);

    // The picture is the screen (02, rule 1): it runs edge to edge and the
    // chrome floats over it in glass. It used to be sandwiched between a
    // bordered control bar above and a bordered encoding strip below, which
    // took ~72 px off the one thing this screen exists to show.
    //
    // Four glass elements, which is the ceiling 05 §14 sets, in the corners it
    // names: top-left frame stats, top-right the render's status, bottom-left
    // the display transfer, bottom-centre the controls.
    return LayoutBuilder(
      builder: (context, constraints) {
        _zoom.box = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            Positioned.fill(child: _canvas(colors, state)),
            // The controls are present even with no pixels to zoom. All four
            // go dead together on a null preview and each states WHY in its
            // accessible name — dropping the row would take that sentence off
            // the screen along with the controls, and the canvas's own empty
            // state is a different sentence about a different thing.
            Positioned(
              left: 0,
              right: 0,
              bottom: SkotiqTokens.spaceMd,
              child: Center(
                child: _DarkroomZoomControls(
                  zoom: _zoom,
                  preview: state.preview,
                  noRenderReason: _darkroomNoRenderReason(state),
                  overImage: true,
                ),
              ),
            ),
            if (state.preview != null) ...[
              Positioned(
                left: SkotiqTokens.spaceMd,
                top: SkotiqTokens.spaceMd,
                child: _frameStats(state),
              ),
              Positioned(
                left: SkotiqTokens.spaceMd,
                right: SkotiqTokens.spaceMd,
                bottom: _hudBottomInset,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: _encodingHud(state),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// How far above the control bar the display-transfer note sits, so the two
  /// bottom-corner elements never overlap on a narrow viewport.
  static const double _hudBottomInset = 64;

  /// The frame's own numbers, top-left, in the corner 05 §14 gives them.
  Widget _frameStats(DarkroomState state) {
    final preview = state.preview!;
    final scale = _zoom.masterScale(preview);
    return Glass(
      child: ReadoutRow(
        gap: SkotiqTokens.spaceLg,
        children: [
          Readout(
            // Null renders an em dash: a render that did not say which pyramid
            // level it answered at cannot be placed against the master, and the
            // readout says so rather than printing 100%.
            value: scale == null ? null : '${(scale * 100).round()}',
            unit: '%',
            label: 'Of master',
            size: ReadoutSize.sm,
          ),
          Readout(
            value: '${preview.width} × ${preview.height}',
            label: 'Rendered',
            size: ReadoutSize.sm,
          ),
          Readout(
            value: preview.level?.toString(),
            label: 'Level',
            size: ReadoutSize.sm,
          ),
        ],
      ),
    );
  }

  /// What the engine did to the pixels for the screen, bottom-left.
  Widget _encodingHud(DarkroomState state) {
    final preview = state.preview!;
    final encoding = preview.encoding;
    final screenTransfer = encoding.screenTransfer;
    return Glass(
      child: Wrap(
        spacing: SkotiqTokens.spaceSm,
        runSpacing: SkotiqTokens.spaceXs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            // The strip describes the render whose pixels are on screen. When
            // a later render failed, those pixels are the previous render's,
            // and saying so here keeps it from reading as an account of the
            // stack the operator is now editing.
            state.renderError == null || state.rendering
                ? 'Display transfer: ${encoding.sentence}'
                : 'Display transfer of the last render that finished: '
                    '${encoding.sentence}',
            style: SkotiqTypography.caption.copyWith(
              color: SkotiqColors.dark.textSecondary,
            ),
          ),
          // The lift's own numbers, behind the tag rather than on the strip:
          // they are what makes "display only" checkable, and they are the
          // engine's, not the recipe's.
          if (screenTransfer != null)
            _DarkroomTag(
              label: 'Screen transfer',
              tooltip: 'The display lift the engine applied, in its own '
                  'numbers: ${_describeParams(screenTransfer)}. It is not a '
                  'step of this recipe, so no export carries it.',
            ),
        ],
      ),
    );
  }

  Widget _canvas(SkotiqColors colors, DarkroomState state) {
    final preview = state.preview;
    if (preview == null) {
      if (state.rendering) {
        return const Center(
            child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
      }
      final renderError = state.renderError;
      if (renderError != null) {
        return EmptyState(
          icon: SkotiqIcons.imageOff,
          title: 'The render did not finish',
          body: renderError,
          action: SkotiqButton(
            label: 'Render again',
            icon: SkotiqIcons.refresh,
            onPressed: () => widget.onRerender(),
          ),
        );
      }
      if (state.cancelledPhase != null) {
        return EmptyState(
          icon: SkotiqIcons.stopCircle,
          title: 'The render was stopped',
          body: 'It stopped during ${state.cancelledPhase}, so there are no '
              'pixels to show yet.',
          action: SkotiqButton(
            label: 'Render again',
            icon: SkotiqIcons.refresh,
            onPressed: () => widget.onRerender(),
          ),
        );
      }
      return const EmptyState(
        icon: SkotiqIcons.image,
        title: 'Nothing rendered yet',
        body:
            'The recipe has not been rendered over this master. Adjust a step '
            'or press Render again.',
      );
    }

    // Why the pixels on screen are not the current stack's, when they are not.
    final failure = state.renderError;

    return Stack(
      children: [
        Positioned.fill(
          // The picture is the primary content of this screen and it published
          // no semantics node at all: a reader walking the Darkroom got the
          // zoom toolbar and the encoding strip, and nothing saying a picture
          // was there, what it was of, or how big it is. The role and the words
          // are here, on the box the pixels are painted in.
          child: Semantics(
            container: true,
            image: true,
            label: darkroomPictureLabel(state, preview),
            child: ColoredBox(
              color: colors.background,
              child: _DarkroomImageSurface(
                preview: preview,
                transform: _transform,
                minScale: kDarkroomMinViewerScale,
                maxScale: kDarkroomMaxViewerScale,
              ),
            ),
          ),
        ),
        // A re-render keeps the previous picture on screen and marks it as
        // stale rather than blanking the canvas: an editor that flashes to
        // empty on every slider frame is unreadable.
        if (state.rendering)
          Positioned(
            top: SkotiqTokens.spaceMd,
            right: SkotiqTokens.spaceMd,
            child: Glass(
              child: _DarkroomTag(
                label: state.cancelRequested ? 'Stopping…' : 'Rendering…',
                tooltip:
                    'The picture below is the previous render until this one '
                    'lands.',
              ),
            ),
          ),
        // A render that FAILED leaves the same superseded picture up, so it
        // gets the same treatment: the staleness is marked here, on the pixels
        // it is about, and the engine's own reason is stated beside it. The
        // Recipe panel says it too, but at phone width that panel is a segment
        // the operator is not looking at — a picture is not labelled by a
        // sentence in a view that is not on screen.
        if (!state.rendering && failure != null) ...[
          Positioned(
            top: SkotiqTokens.spaceMd,
            right: SkotiqTokens.spaceMd,
            child: Glass(
              child: _DarkroomTag(
                label: 'Stale — the render did not finish',
                tooltip:
                    'The picture below is the last render that finished, not '
                    'the stack as it stands now: $failure',
              ),
            ),
          ),
          // Positioned.fill, so the alert is laid out inside the canvas rather
          // than growing past its top edge and painting over the zoom controls
          // on a short viewport.
          Positioned.fill(
            child: Align(
              alignment: Alignment.bottomCenter,
              // Bounded and scrollable, because nothing bounds this sentence:
              // the engine names the master by its absolute path, and a deep
              // capture directory alone is enough to push the card past a phone
              // segment's canvas — which paints the reason as a striped
              // overflow bar with its last lines simply gone. Half the canvas
              // is the ceiling, and a card shorter than that still lays out at
              // its own height, so the common case is unchanged.
              //
              // The pass-through this replaces was worth less than the words:
              // it let a drag over the card pan a picture the same card is
              // explaining is stale, and the picture above the card is still
              // pannable either way.
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: _zoom.box.height / 2,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                  child: SkotiqBanner(
                    tone: BannerTone.error,
                    title: 'The render did not finish',
                    message: '$failure\n\nThis picture is the last render that '
                        'finished, so it does not show the stack as it stands.',
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// A parameter map as `key value` pairs in a stable order.
  static String _describeParams(Map<String, dynamic> params) {
    final keys = params.keys.toList()..sort();
    return [for (final key in keys) '$key ${params[key]}'].join(', ');
  }
}

/// A small labelled tag with an explanation behind it.
///
/// Deliberately not colour-coded: under the red-night palette every semantic
/// hue collapses toward the same red, so a tag that carried meaning in its fill
/// alone would say nothing at the telescope.
class _DarkroomTag extends StatelessWidget {
  final String label;
  final String tooltip;

  const _DarkroomTag({required this.label, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    // A chip is a chip (05 §10): 22 px, solid `surfaceHover`, `radiusXs`, no
    // border. It was a hand-rolled bordered box with its own padding and text
    // size, which is the "second style of something" 02's fourth rule forbids.
    return Tooltip(message: tooltip, child: SkotiqChip(label: label));
  }
}
