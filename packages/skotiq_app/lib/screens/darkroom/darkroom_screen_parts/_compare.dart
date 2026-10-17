part of '../darkroom_screen.dart';

/// How long each side of a blink compare holds before the other takes over.
///
/// Long enough to read the frame, short enough that the eye holds the previous
/// one — the interval visual comparison has used since blink comparators were
/// mechanical.
const Duration kDarkroomBlinkInterval = Duration(milliseconds: 700);

/// The two sides of a compare, in the one letter every label on this view names
/// them by.
const String _kDarkroomCompareSideA = 'A';
const String _kDarkroomCompareSideB = 'B';

/// Why the compare row's zoom controls are unavailable.
///
/// It takes BOTH panes failing. One transform moves both viewers, so a single
/// pane that did not render leaves the other one's pixels there to be zoomed —
/// which is what the compare picker promises when it says zoom and pan stay
/// locked together.
const String kDarkroomCompareNeitherPaneRendered =
    'neither pane has a finished render to zoom';

/// How the compare pane draws its two recipes.
enum _DarkroomCompareMode {
  /// Both renders at once, side by side on a wide screen and stacked on a
  /// phone.
  sideBySide,

  /// One render at a time in the same rectangle, alternating. The only way to
  /// see a small change: two pictures side by side are compared by moving the
  /// eye, which loses exactly the differences a blink makes obvious.
  blink,
}

/// Two recipes over one master, rendered together.
///
/// **One transform, two viewers.** Both panes are handed the SAME
/// [TransformationController], so a drag-pan or a pinch in either moves both.
/// A per-pane controller kept in step by a callback would come apart the moment
/// the operator dragged, because a drag reaches no callback. The controller is
/// owned here and disposed here; the surface never disposes one it did not
/// create.
///
/// **Each pane mounts once.** Both modes build both panes — side by side paints
/// them together, blink paints one at a time — so neither swap tears a pane's
/// decoded frame down. Nothing in either path carries a `GlobalKey`: two panes
/// are the same widget type over the same data, and a shared static key is how
/// the second one silently fails to mount in a release build.
///
/// **Both sides render the same master at the same preview budget**, so they
/// answer at the same pyramid level and one transform describes both. What
/// differs on screen is therefore the recipe and nothing else — which is the
/// only reason an A/B compare means anything.
class _DarkroomCompareView extends ConsumerStatefulWidget {
  /// The open recipe's live state — including edits that have not reached the
  /// row yet, which is what makes "compare with the draft" meaningful.
  final DarkroomState aState;

  /// The label the A side carries.
  final String aLabel;

  /// The recipe rendered on the B side.
  final int bRecipeId;

  /// The label the B side carries.
  final String bLabel;

  /// Whether the B side is the dawn autopilot's own draft.
  final bool bIsAutopilotDraft;

  final _DarkroomCompareMode mode;

  const _DarkroomCompareView({
    required this.aState,
    required this.aLabel,
    required this.bRecipeId,
    required this.bLabel,
    required this.bIsAutopilotDraft,
    required this.mode,
  });

  @override
  ConsumerState<_DarkroomCompareView> createState() =>
      _DarkroomCompareViewState();
}

class _DarkroomCompareViewState extends ConsumerState<_DarkroomCompareView> {
  /// The transform both panes share, and the operations the zoom controls
  /// perform on it. Owned here so the two viewers cannot disagree about where
  /// the operator is looking.
  final _DarkroomZoom _zoom = _DarkroomZoom();

  TransformationController get _transform => _zoom.controller;

  Timer? _blink;

  /// Which side a blink is currently showing.
  bool _showingA = true;

  /// True while the operator holds the compare control down, which pins the B
  /// side up regardless of the blink.
  bool _held = false;

  @override
  void initState() {
    super.initState();
    // The readout is a number about the transform, and a drag-pan or a pinch
    // reaches no callback of this widget's — so it listens to the controller,
    // the same way the single-recipe viewport does.
    _transform.addListener(_onTransformChanged);
    if (widget.mode == _DarkroomCompareMode.blink) _startBlink();
  }

  /// Repaint the readout on the next legal frame.
  ///
  /// The panes write the initial fit to this controller from inside a layout
  /// callback; marking this widget dirty there asks for a build during a layout
  /// already in flight, which release builds drop along with the enclosing
  /// panel's build scope. See [_DarkroomViewportState._onTransformChanged],
  /// where the same trap was measured.
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

  @override
  void didUpdateWidget(covariant _DarkroomCompareView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.mode != oldWidget.mode ||
        widget.bRecipeId != oldWidget.bRecipeId) {
      _stopBlink();
      _showingA = true;
      if (widget.mode == _DarkroomCompareMode.blink) _startBlink();
    }
  }

  @override
  void dispose() {
    _stopBlink();
    _transform.removeListener(_onTransformChanged);
    _zoom.dispose();
    super.dispose();
  }

  void _startBlink() {
    _blink = Timer.periodic(kDarkroomBlinkInterval, (_) {
      if (!mounted) return;
      setState(() => _showingA = !_showingA);
    });
  }

  void _stopBlink() {
    _blink?.cancel();
    _blink = null;
  }

  bool get _blinking => _blink != null;

  /// Which side is on screen right now in blink mode: the hold wins over the
  /// timer, so "hold to compare" is a deliberate look rather than a race with
  /// the next tick.
  bool get _showA => _held ? false : _showingA;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final bState = ref.watch(
      darkroomControllerProvider(DarkroomScope.recipe(widget.bRecipeId)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _controls(bState),
        Expanded(
          child: widget.mode == _DarkroomCompareMode.sideBySide
              ? _sideBySide(colors, bState)
              : _blinkPane(colors, bState),
        ),
      ],
    );
  }

  /// One control row above both panes: the mode controls this view owns, then
  /// the SAME zoom controls the single-recipe viewport carries.
  ///
  /// Compare used to build its own chrome and drop the toolbar entirely, so the
  /// comparator had no zoom control, no percentage readout and no way to reach
  /// 1:1 — the magnification an A/B noise comparison is for — with the mouse
  /// wheel as the only way to change the view at all. The controls drive the
  /// one shared transform, so both panes stay locked exactly as the picker
  /// promises.
  ///
  /// **One pane's failure does not take the zoom away from the other.** The row
  /// was handed A's render alone, so a branch whose stack does not validate —
  /// an out-of-range parameter is enough — left all four controls dead over a
  /// B pane that was still drawing a picture and still zooming under the mouse
  /// wheel, seconds after the picker promised zoom and pan stay locked
  /// together. There is one transform and it moves whatever has pixels, so the
  /// controls operate over whichever pane has a render and the readout names
  /// the side it measured. Dead controls are kept for the case that is really
  /// dead — neither pane rendered — and then they say so.
  Widget _controls(DarkroomState bState) {
    final blinkMode = widget.mode == _DarkroomCompareMode.blink;
    // A's render when A has one, because A is the stack this editor is showing.
    // When B's render answered from a different pyramid level, one percentage
    // cannot describe both sides — and that is said rather than left to be read
    // off a number that is right about one pane only.
    final aScale = widget.aState.preview?.scaleFromMaster;
    final bScale = bState.preview?.scaleFromMaster;
    final zoomed = widget.aState.preview ?? bState.preview;
    final measuredOn = widget.aState.preview == null && zoomed != null
        ? _kDarkroomCompareSideB
        : null;
    return _DarkroomZoomControls(
      zoom: _zoom,
      preview: zoomed,
      measuredOn: measuredOn,
      noRenderReason: kDarkroomCompareNeitherPaneRendered,
      leading: [
        _DarkroomTag(
          label: blinkMode ? (_showA ? 'Showing A' : 'Showing B') : 'A | B',
          tooltip: 'A is "${widget.aLabel}" — this editor\'s current stack, '
              'unsaved edits included. B is "${widget.bLabel}".',
        ),
        if (blinkMode)
          SkotiqButton(
            label: _blinking ? 'Pause blink' : 'Resume blink',
            icon: _blinking ? SkotiqIcons.pause : SkotiqIcons.play,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () {
              if (_blinking) {
                _stopBlink();
              } else {
                _startBlink();
              }
              setState(() {});
            },
          ),
        // Blink only. Side by side already has both renders on screen, so
        // pinning B there changes nothing — and a control that publishes an
        // on/off state while changing nothing on screen is the shape of every
        // dead control in this app's history.
        if (blinkMode) _holdToCompare(),
      ],
      trailing: [
        if (zoomed?.level != null)
          _DarkroomTag(
            label: 'Level ${zoomed!.level}',
            tooltip: measuredOn == null
                ? 'The pyramid level the A side was rendered from. The '
                    'percentage beside it is about A.'
                : 'The pyramid level the $measuredOn side was rendered from. A '
                    'has no finished render, so the percentage beside it is '
                    'about $measuredOn.',
          ),
        if (aScale != null && bScale != null && aScale != bScale)
          _DarkroomTag(
            label: 'B answered at another level',
            tooltip: 'The two sides rendered from different pyramid levels, so '
                'the percentage is about A alone. B is level '
                '${bState.preview!.level}.',
          ),
        if (bState.rendering)
          const _DarkroomTag(
            label: 'B is rendering…',
            tooltip:
                'The B side renders through the same engine as A, one recipe '
                'at a time, so it can lag a moment behind.',
          ),
        if (bState.renderError != null)
          _DarkroomTag(
            label: 'B did not render',
            tooltip: bState.renderError!,
          ),
      ],
    );
  }

  /// Press-and-hold to see the other recipe, release to come back.
  ///
  /// The cheapest honest form of "compare with the draft": while it is held the
  /// B side is on screen, and B is whichever recipe the branch bar chose — the
  /// autopilot's draft when that is what was picked.
  Widget _holdToCompare() {
    return _DarkroomHoldToCompare(
      label: widget.bIsAutopilotDraft
          ? 'Hold to see the autopilot draft'
          : 'Hold to see ${widget.bLabel}',
      held: _held,
      onHeldChanged: (held) => setState(() => _held = held),
    );
  }

  Widget _sideBySide(SkotiqColors colors, DarkroomState bState) {
    final panes = [
      _pane(colors, widget.aLabel, _kDarkroomCompareSideA, widget.aState),
      _pane(colors, widget.bLabel, _kDarkroomCompareSideB, bState),
    ];
    // A phone reflows into a stack rather than shrinking both panes into
    // thumbnails: two 180-pixel-wide renders compare nothing.
    if (Responsive.isPhone(context)) {
      return Column(
        children: [
          Expanded(child: panes[0]),
          Container(height: 1, color: colors.border),
          Expanded(child: panes[1]),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: panes[0]),
        Container(width: 1, color: colors.border),
        Expanded(child: panes[1]),
      ],
    );
  }

  /// Blink keeps BOTH panes mounted and paints one of them.
  ///
  /// Building only the showing side tore the other one down on every tick, so
  /// each swap re-mounted a pane with no decoded frame and the comparator
  /// showed a blank for roughly half of each 700 ms cycle — destroying the
  /// afterimage that is the entire reason to blink rather than look side by
  /// side. Two mounted panes hold their own decoded frames, so the swap is a
  /// buffer change with nothing in between.
  ///
  /// [IndexedStack] rather than opacity or offstage: it lays both out, paints
  /// only the indexed one, and walks only that one for semantics, so the hidden
  /// recipe is not announced as being on screen.
  Widget _blinkPane(SkotiqColors colors, DarkroomState bState) {
    return IndexedStack(
      index: _showA ? 0 : 1,
      sizing: StackFit.expand,
      children: [
        _pane(colors, widget.aLabel, _kDarkroomCompareSideA, widget.aState),
        _pane(colors, widget.bLabel, _kDarkroomCompareSideB, bState),
      ],
    );
  }

  Widget _pane(
    SkotiqColors colors,
    String label,
    String side,
    DarkroomState state,
  ) {
    final preview = state.preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: colors.surface,
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceMd,
            vertical: SkotiqTokens.spaceXs,
          ),
          child: Text(
            '$side · $label',
            style: SkotiqTypography.labelSm.copyWith(
              color: colors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Both panes lay out at the same size, so either one measures the
              // box the shared zoom operates over; fit and 1:1 both need it.
              _zoom.box = Size(constraints.maxWidth, constraints.maxHeight);
              return ColoredBox(
                color: colors.background,
                child: preview == null
                    ? _paneEmpty(state)
                    // The pane published no semantics node at all: a reader
                    // walking an A/B compare — the one view whose entire
                    // purpose is reading a difference between two pictures —
                    // was never told a picture was there, what it was of, or
                    // which side it was. The single-recipe viewport's own
                    // comment records the same defect being fixed there; this
                    // path still had the pre-fix shape.
                    : Semantics(
                        container: true,
                        image: true,
                        label: 'Compare pane $side of two. '
                            '${darkroomPictureLabel(
                          state,
                          preview,
                          name: label,
                        )}',
                        child: _DarkroomImageSurface(
                          preview: preview,
                          transform: _transform,
                          minScale: kDarkroomMinViewerScale,
                          maxScale: kDarkroomMaxViewerScale,
                        ),
                      ),
              );
            },
          ),
        ),
        if (preview != null)
          Container(
            width: double.infinity,
            color: colors.surface,
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceMd,
              vertical: 2,
            ),
            child: Text(
              'Display transfer: ${preview.encoding}',
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textMuted,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _paneEmpty(DarkroomState state) {
    if (state.loading || state.rendering) {
      return const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
    }
    final loadError = state.loadError;
    if (loadError != null) {
      return EmptyState.compact(
        icon: SkotiqIcons.imageOff,
        title: 'This side could not be opened',
        body: loadError,
      );
    }
    final renderError = state.renderError;
    if (renderError != null) {
      return EmptyState.compact(
        icon: SkotiqIcons.imageOff,
        title: 'This side did not render',
        body: renderError,
      );
    }
    return const EmptyState.compact(
      icon: SkotiqIcons.image,
      title: 'Nothing rendered yet',
      body: 'This recipe has not produced a picture over the master yet.',
    );
  }
}

/// A press-and-hold control: held means "show the other recipe".
///
/// Hand-rolled rather than a [SkotiqButton] because the gesture IS the
/// control for a pointer. A button's callback fires on release, which is the
/// moment this affordance ends; wiring one to an empty closure to borrow the
/// styling would leave a control that looks pressable and does nothing on tap.
///
/// **A hold is not the only way to work it.** A press-and-hold cannot be
/// performed from a keyboard or from assistive tech, and the earlier shape —
/// `Semantics(button)` over an `ExcludeSemantics(GestureDetector)` — published
/// a node with no tap action and no enabled state, which the AT-SPI bridge
/// reported as `Hold to see … [DISABLED]`: a control that read as broken and
/// could not be operated at all. So the same control is also a TOGGLE: it
/// carries `toggled`, publishes tap and long-press actions, takes keyboard
/// focus, and Enter/Space pin the other recipe up and release it again. The
/// pointer path is unchanged — press pins, release comes back.
class _DarkroomHoldToCompare extends StatefulWidget {
  final String label;
  final bool held;
  final ValueChanged<bool> onHeldChanged;

  const _DarkroomHoldToCompare({
    required this.label,
    required this.held,
    required this.onHeldChanged,
  });

  @override
  State<_DarkroomHoldToCompare> createState() => _DarkroomHoldToCompareState();
}

class _DarkroomHoldToCompareState extends State<_DarkroomHoldToCompare> {
  /// True while the keyboard focus ring is on this control.
  bool _focused = false;

  void _toggle() => widget.onHeldChanged(!widget.held);

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final held = widget.held;
    final active = held || _focused;
    return Semantics(
      button: true,
      // Stated, not implied: `Semantics` publishes the isEnabled flag only when
      // the field is given, and without it the AT-SPI bridge reports the
      // working control as disabled.
      enabled: true,
      toggled: held,
      label: widget.label,
      hint: held
          ? 'Showing the other recipe. Release the press, or activate this '
              'control again, to come back.'
          : 'Press and hold to show the other recipe; release to come back. '
              'From a keyboard, activate it to pin the other recipe up and '
              'activate it again to come back.',
      // The actions the pointer gesture cannot offer assistive tech. Both land
      // on the same toggle, so an activation pins B up and the next one
      // releases it — the explicit release a hold has no way to express.
      onTap: _toggle,
      onLongPress: _toggle,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (value) {
          if (!mounted || _focused == value) return;
          setState(() => _focused = value);
        },
        actions: <Type, Action<Intent>>{
          // Enter and Space arrive as ActivateIntent from the app-level default
          // shortcuts; ButtonActivateIntent is the web variant.
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        // The gesture keeps its own semantics out of the way: a
        // `TapGestureRecognizer` publishes its own tap action, which would
        // collide with the one declared above and split this control into two
        // nodes — a named one with no action over an anonymous one with the
        // action.
        child: ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => widget.onHeldChanged(true),
            onTapUp: (_) => widget.onHeldChanged(false),
            onTapCancel: () => widget.onHeldChanged(false),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceSm,
                vertical: SkotiqTokens.spaceXs,
              ),
              decoration: BoxDecoration(
                color: held ? colors.surfaceHover : colors.surface,
                borderRadius: SkotiqTokens.borderRadiusSm,
                border: Border.all(
                  color: active ? colors.primary : colors.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    SkotiqIcons.visible,
                    size: SkotiqTokens.iconSm,
                    color: active ? colors.primary : colors.textSecondary,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceXs),
                  Text(
                    widget.label,
                    style: SkotiqTypography.labelSm.copyWith(
                      color: active ? colors.primary : colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
