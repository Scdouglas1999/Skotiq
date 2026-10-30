part of '../darkroom_editor.dart';

/// Longest account this panel states without being asked.
///
/// The Recipe panel shares its column with the History stack, so its viewport
/// is a couple of hundred pixels: an account longer than this runs past the
/// fold, and the operator reads a sentence that stops in the middle of a clause
/// with nothing to say the rest exists.
///
/// Measured, not guessed: on a 1600x900 desktop with the panel at its 360-pixel
/// default, the alert's message column holds about 28 characters a line and the
/// panel's viewport gives the alert about four of them beneath its heading. So
/// the collapsed account is sized to sit inside that block WITH the control
/// that opens it, rather than to a round number that then runs past the fold
/// again.
const int kDarkroomDraftNoteCollapsedChars = 100;

/// A long account stated in full inside ONE alert, collapsed to its first few
/// lines with the control that opens it in the alert's own block.
///
/// Long accounts collapse at a WORD boundary and say so, rather than being
/// sliced wherever the panel's scroll fold happens to fall. The cut is the
/// widget's own and it is marked, so "…" plus a control that names the rest is
/// the difference between text that was shortened and text that looks broken.
///
/// The control lives in the alert's `action` slot rather than under the alert.
/// Under it, the control was a separate row in the panel's scroll view: the
/// alert sat above the fold and the button that completed its sentence sat one
/// line below it, so the operator saw a clause cut off with — as far as the
/// screen was concerned — nothing that said the rest existed. Inside the alert
/// the control cannot be scrolled away from the text it discloses; they share a
/// viewport because they share a box. It costs the message column the button's
/// width, which is less than the row the button used to occupy underneath.
///
/// The disclosure NAMES WHAT IT OPENS. This panel shows more than one of these
/// at once — an autopilot draft over a one-channel master carries both "The
/// draft left 2 operations out" and "The integration recorded 5 calibration
/// warnings" — and measured on the release bundle 2026-08-31 both published
/// `button: 'Show more'`, side by side, with nothing to tell a reader which
/// account each one completes. The word on screen stays "Show more", because it
/// sits inside the alert whose text it continues; [disclosureObject] is what
/// assistive tech reads instead, the way "Remove Denoise" and "Use default for
/// Stretch intensity" are read elsewhere on this screen.
class _DarkroomCollapsibleAlert extends StatefulWidget {
  const _DarkroomCollapsibleAlert({
    required this.message,
    required this.tone,
    required this.disclosureObject,
    required this.title,
  });

  /// SkotiqBanner puts the title and the message on ONE line, so the title
  /// is required: a banner with no title starts mid-sentence.
  final String title;
  final String message;
  final BannerTone tone;

  /// What the expander opens, named as an object: "the draft's omissions".
  final String disclosureObject;

  @override
  State<_DarkroomCollapsibleAlert> createState() =>
      _DarkroomCollapsibleAlertState();
}

class _DarkroomCollapsibleAlertState extends State<_DarkroomCollapsibleAlert> {
  bool _expanded = false;

  /// A different account starts collapsed again.
  ///
  /// This widget keeps its position when the panel swaps branches, so without
  /// this the next recipe's account would open expanded because the operator
  /// opened the LAST one — and the panel it is in would be past its fold before
  /// they had read a word of it.
  @override
  void didUpdateWidget(_DarkroomCollapsibleAlert oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message) _expanded = false;
  }

  /// [text] cut to at most [kDarkroomDraftNoteCollapsedChars] characters at a
  /// word boundary, or null when the whole of it already fits.
  ///
  /// A cut that lands inside a word is the very thing this exists to avoid, so
  /// the last space at or before the limit is where it falls. Text with no such
  /// space — one long unbroken token — is left whole rather than chopped
  /// mid-token.
  static String? _collapsed(String text) {
    if (text.length <= kDarkroomDraftNoteCollapsedChars) return null;
    final boundary =
        text.lastIndexOf(RegExp(r'\s'), kDarkroomDraftNoteCollapsedChars);
    if (boundary <= 0) return null;
    return '${text.substring(0, boundary)}…';
  }

  /// Open or close the account, and when opening, bring it into the panel's
  /// view.
  ///
  /// The alert grows where it stands, and this panel's viewport is a few
  /// hundred pixels: measured on the release bundle 2026-08-31, opening "the
  /// draft's omissions" left the first paragraph sliced mid-word at the scroll
  /// edge, the second paragraph entirely below it, and pushed the Render block
  /// that HAD been visible out of sight — an operator pressing "Show more" was
  /// shown less. The scroll runs after the frame that lays the expanded alert
  /// out, because only then does the viewport know how tall this is now, and it
  /// aligns the alert's top with the panel's so as much of the newly revealed
  /// text as fits is on screen.
  ///
  /// Closing scrolls nothing: the alert shrinks back to where it was, and the
  /// reader is already looking at it.
  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (!_expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final collapsed = _collapsed(widget.message);
    final showing =
        (collapsed == null || _expanded) ? widget.message : collapsed;
    return SkotiqBanner(
      tone: widget.tone,
      title: widget.title,
      message: showing,
      action: collapsed == null
          ? null
          : _DarkroomNamedControl(
              label: _expanded
                  ? 'Show less about ${widget.disclosureObject}'
                  : 'Show more about ${widget.disclosureObject}',
              onPressed: _toggle,
              child: SkotiqButton(
                label: _expanded ? 'Show less' : 'Show more',
                icon:
                    _expanded ? SkotiqIcons.chevronUp : SkotiqIcons.chevronDown,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: _toggle,
              ),
            ),
    );
  }
}

/// What this recipe is, what the last render did with it, and the edits that
/// act on the stack as a whole.
///
/// The panel is taller than the slot it is given, so it scrolls — and a scroll
/// region whose only cue is a line sliced in half at the fold reads as a bug
/// rather than as an invitation. Its scrollbar is therefore always drawn, and
/// the one thing on the panel that reports something NOT happening — the
/// color calibration having no catalogue stars — is placed above the fold
/// instead of a scroll away.
class _DarkroomRecipePanel extends StatefulWidget {
  final DarkroomState state;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onResetToLinear;
  final Future<void> Function() onRerender;

  const _DarkroomRecipePanel({
    required this.state,
    required this.onUndo,
    required this.onRedo,
    required this.onResetToLinear,
    required this.onRerender,
  });

  @override
  State<_DarkroomRecipePanel> createState() => _DarkroomRecipePanelState();
}

/// How far the fade at a scroll edge reaches, as a fraction of the viewport.
///
/// Short enough that it never dims a whole line into unreadability, long enough
/// that the line at the edge visibly trails off rather than ending in a clean
/// cut a reader takes for the end of the text.
const double _kRecipePanelFadeFraction = 0.055;

/// Which edges of a scroll region have content behind them.
///
/// Taken from the metrics rather than from the controller so the same reading
/// serves a scroll and a metrics-only change alike — the content GROWING when a
/// disclosure opens is the second kind, and it is the one the panel most needs
/// to follow. A region with nothing off-screen answers false to both: a fade
/// there would claim there is more to read when there is not.
///
/// Half a pixel of slack, because a viewport and its content agreeing exactly
/// is a floating-point coincidence, not a promise.
({bool above, bool below}) darkroomScrollEdges(ScrollMetrics metrics) {
  if (!metrics.hasPixels || !metrics.hasContentDimensions) {
    return (above: false, below: false);
  }
  return (
    above: metrics.extentBefore > 0.5,
    below: metrics.extentAfter > 0.5,
  );
}

/// The mask that fades whichever edge of the recipe panel has more behind it.
///
/// Alpha only — the panel is painted over whatever the surface behind it is, so
/// the fade dims the text into that surface rather than into an invented
/// colour.
LinearGradient darkroomRecipePanelEdgeMask({
  required bool above,
  required bool below,
}) {
  const opaque = ImageOverlayColors.shadow;
  const clear = Colors.transparent;
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      above ? clear : opaque,
      opaque,
      opaque,
      below ? clear : opaque,
    ],
    stops: const [
      0.0,
      _kRecipePanelFadeFraction,
      1.0 - _kRecipePanelFadeFraction,
      1.0,
    ],
  );
}

class _DarkroomRecipePanelState extends State<_DarkroomRecipePanel> {
  /// Owned here because an always-visible scrollbar needs the controller its
  /// scroll view uses; there is no ambient one in a side panel.
  final ScrollController _scroll = ScrollController();

  /// Whether the region holds content past its top and bottom edges.
  ///
  /// The panel's only cue that it scrolled was a 2-pixel scrollbar thumb, so a
  /// paragraph sliced clean through the glyphs at the fold read as broken
  /// rendering rather than as text that continues. These drive a fade at
  /// whichever edge has more behind it: a line that dims out is a line the
  /// reader knows to scroll for.
  bool _moreAbove = false;
  bool _moreBelow = false;

  DarkroomState get state => widget.state;

  /// Take the edge flags from [metrics], and rebuild only when they moved.
  ///
  /// Called for scrolls AND for metric changes that no scroll caused — the
  /// content growing when a disclosure opens is exactly that, and it is the
  /// case the fade most needs to follow.
  void _readEdges(ScrollMetrics metrics) {
    if (!mounted) return;
    final edges = darkroomScrollEdges(metrics);
    if (edges.above == _moreAbove && edges.below == _moreBelow) return;
    setState(() {
      _moreAbove = edges.above;
      _moreBelow = edges.below;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Inset to the same gutter the panel's own content uses. SectionHeader
        // pads vertically only, and on the phone's segmented layout this panel
        // IS the screen — nothing outside it supplies a margin, so without this
        // the heading starts at the window edge while every card under it is
        // indented.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceMd),
          child: SectionTitle(icon: SkotiqIcons.sliders, title: 'Recipe'),
        ),
        Expanded(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              _readEdges(notification.metrics);
              return false;
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                _readEdges(notification.metrics);
                return false;
              },
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                // The mask is inside the scrollbar so the fade dims the text
                // and not the thumb — the thumb is the other half of the same
                // message.
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => darkroomRecipePanelEdgeMask(
                    above: _moreAbove,
                    below: _moreBelow,
                  ).createShader(bounds),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                      SkotiqTokens.spaceMd,
                      SkotiqTokens.spaceMd,
                      SkotiqTokens.spaceLg,
                      SkotiqTokens.spaceLg,
                    ),
                    // Ordered by what has to be readable without scrolling: the
                    // controls, then the account of the last render (its status
                    // and the reason a step did NOT run). The base master and
                    // the two paragraphs about it are reference — true, worth
                    // keeping, and the right thing to put below the fold, since
                    // they were what pushed the skip reason off the bottom of
                    // the card.
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _editActions(colors),
                        const SizedBox(height: SkotiqTokens.spaceLg),
                        // Above the render account and far above the reference
                        // material: both of these say what this recipe IS —
                        // what the registry decided to leave out of it, and
                        // what file it was read from — and neither is
                        // inferable from the stack.
                        ..._provenance(),
                        _renderStatus(colors),
                        if (state.preview case final preview?) ...[
                          const SizedBox(height: SkotiqTokens.spaceLg),
                          _DarkroomHistogramCard(preview: preview),
                        ],
                        // Both halves of the photometry account — the stars
                        // there are, and the reason there are none — belong to
                        // one step. A stack that does not carry that step is
                        // not waiting on a catalogue for anything, so neither
                        // half is stated.
                        if (state.hasColorCalibrateStep &&
                            state.photometryStarCount > 0) ...[
                          const SizedBox(height: SkotiqTokens.spaceMd),
                          Text(
                            '${state.photometryStarCount} catalogue stars are '
                            'lent to the color calibration on every render. It '
                            'solves the balance from them each time rather '
                            'than storing fitted channel scales, so a coarse '
                            'preview level can detect too few stars and record '
                            'the step as skipped.',
                            style: SkotiqTypography.captionSm.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                        const SizedBox(height: SkotiqTokens.spaceLg),
                        _identity(colors),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// What this recipe is, beyond its steps: what the registry decided about and
  /// did not carry, and what file an import read it from.
  ///
  /// The draft notes are the composing pass's own account, now read off the
  /// recipe row — so the dawn autopilot's draft opens carrying them and a
  /// Reload keeps them, where before they lived only in the night report on
  /// disk and in one session's memory. "Color where there is color to
  /// calibrate" is a promise the offer makes; a mono master's four-step stack
  /// is what arrives; the sentence in between is this.
  List<Widget> _provenance() {
    final notes = state.statedDraftNotes;
    final notesError = state.draftNotesError;
    final importNote = state.importNote;
    if (notes.isEmpty && notesError == null && importNote == null) {
      return const [];
    }
    return [
      if (notesError != null) ...[
        SkotiqBanner(
          tone: BannerTone.warning,
          title: 'The draft account could not be read',
          message: notesError,
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
      ],
      if (notes.isNotEmpty) ...[
        _DarkroomCollapsibleAlert(
          tone: BannerTone.info,
          title: _draftNotesTitle(notes),
          disclosureObject: "the draft's omissions",
          message: [
            for (final note in notes) darkroomDraftNoteSentence(note),
          ].join('\n\n'),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
      ],
      if (importNote != null) ...[
        SkotiqBanner(
          tone: BannerTone.info,
          title: 'Imported from a .skrecipe sidecar',
          message: importNote,
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
      ],
    ];
  }

  /// Which of the three ways this stack came to be.
  String _authorLabel() {
    if (state.author == RecipeAuthor.autopilot) {
      return 'Drafted by the autopilot';
    }
    return state.composedByRegistry
        ? 'Drafted at your request'
        : 'Written by you';
  }

  /// The heading over a block of draft notes.
  ///
  /// An omission is the operation the draft LEFT OUT; the other outcomes are
  /// about operations it carried and had to work for. The heading counts what
  /// is under it and says which of the two it is counting, rather than calling
  /// a re-measured step an omitted one.
  static String _draftNotesTitle(List<RecipeDraftNote> notes) {
    final omitted = notes.where((note) => note.outcome == 'omitted').length;
    if (omitted != notes.length) return 'How this draft was composed';
    return omitted == 1
        ? 'The draft left one operation out'
        : 'The draft left $omitted operations out';
  }

  Widget _identity(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: SkotiqTokens.spaceXs,
          runSpacing: SkotiqTokens.spaceXs,
          children: [
            // The tag says who COMPOSED the step list. A stack the operation
            // registry measured is a first interpretation whether the dawn pass
            // asked for it or the operator pressed "Draft for me" — and calling
            // the second one "Written by you" credited the operator with steps
            // they never chose, stripping exactly the caveat the tag exists to
            // carry.
            _DarkroomTag(
              label: _authorLabel(),
              tooltip:
                  'Who composed the step list as it stands. A drafted stack is '
                  'the operation registry\'s first interpretation of these '
                  'pixels — measured, not decided — and every step in it is '
                  'yours to change. "Written by you" means every step in the '
                  'stack was your own choice.',
            ),
            if (state.isLinear)
              const _DarkroomTag(
                label: 'Linear',
                tooltip: 'Every step is switched off, so the viewport is the '
                    'master\'s own pixels. Nothing was destroyed — each step '
                    'and its parameters are intact.',
              ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          'Base master',
          style: SkotiqTypography.labelSm.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: 2),
        Tooltip(
          message: state.baseMasterPath,
          child: Text(
            state.baseMasterPath,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.monoSm.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          'Nothing in this screen writes to that file. Every step is stored as '
          'data and replayed over it.',
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
        ..._calibration(colors),
      ],
    );
  }

  /// What the integration recorded about the calibration behind these pixels.
  ///
  /// The provenance block named who wrote the stack and which file it replays
  /// over, and stopped there — while the one fact that changes what every step
  /// above it MEANS went unsaid. A gradient over lights that never had a flat
  /// applied is a sensor signature; a background extraction "fixes" it and the
  /// operator ships a master with the vignette folded into the sky model. The
  /// master FITS carries this as `CALWARN`, the morning report prints it, and
  /// the editor — the one screen where the decision is actually made — did not.
  ///
  /// Read from the master's own row, through the same parse the morning report
  /// uses. A recipe with no library row states nothing rather than guessing:
  /// the record belongs to the master, and a master this build cannot find has
  /// no record to quote.
  List<Widget> _calibration(SkotiqColors colors) {
    final stats = state.masterCalibration;
    if (stats == null) return const [];
    if (stats.calibration.isEmpty && !stats.calibrationWarned) return const [];

    final warnings = stats.calibrationSentences;
    return [
      const SizedBox(height: SkotiqTokens.spaceMd),
      Text(
        'Calibration applied',
        style: SkotiqTypography.labelSm.copyWith(
          color: colors.textSecondary,
        ),
      ),
      const SizedBox(height: 2),
      for (final slot in stats.calibration)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            // The slot's own two facts, in its own words: whether the
            // correction RAN, and the quality the matcher recorded for it. A
            // row that said only "dark" would leave "applied" and "missing"
            // looking identical.
            '${_capitalized(slot.kind)}: '
            '${slot.applied ? 'applied' : 'not applied'} · ${slot.quality}',
            style: SkotiqTypography.captionSm.copyWith(
              color: slot.isWarning ? colors.warning : colors.textSecondary,
            ),
          ),
        ),
      if (stats.cosmeticCorrection != null)
        Text(
          'Cosmetic correction: '
          '${stats.cosmeticCorrection! ? 'ran per light' : 'did not run'}',
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textSecondary,
          ),
        ),
      if (warnings.isNotEmpty) ...[
        const SizedBox(height: SkotiqTokens.spaceSm),
        _DarkroomCollapsibleAlert(
          tone: BannerTone.warning,
          title: warnings.length == 1
              ? 'The integration recorded a calibration warning'
              : 'The integration recorded ${warnings.length} calibration '
                  'warnings',
          disclosureObject: 'the calibration warnings',
          message: warnings.join('\n\n'),
        ),
      ],
    ];
  }

  static String _capitalized(String value) =>
      value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

  Widget _editActions(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SkotiqButton(
                label: 'Undo',
                icon: SkotiqIcons.undo,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: state.canUndo ? widget.onUndo : null,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: SkotiqButton(
                label: 'Redo',
                icon: SkotiqIcons.repeat,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: state.canRedo ? widget.onRedo : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqButton(
          label: 'Reset to linear',
          icon: SkotiqIcons.frame,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: state.steps.isEmpty || state.isLinear
              ? null
              : widget.onResetToLinear,
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          'Switches every step off. Nothing is deleted, and one undo brings '
          'the whole stack back.',
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _renderStatus(SkotiqColors colors) {
    final children = <Widget>[
      Text(
        'Render',
        style: SkotiqTypography.labelSm.copyWith(
          color: colors.textSecondary,
        ),
      ),
      const SizedBox(height: SkotiqTokens.spaceXs),
    ];

    if (state.rendering) {
      children.add(
        SkotiqProgressBar(
          // The engine reports no fraction for a preview render, so the bar is
          // indeterminate rather than inventing progress.
          value: 0.0,
          indeterminate: true,
          style: SkotiqProgressStyle.standard,
          state: SkotiqProgressState.normal,
          label: state.cancelRequested
              ? 'Stopping at the next step boundary…'
              : 'Rendering the stack…',
        ),
      );
    } else {
      final error = state.renderError;
      final cancelled = state.cancelledPhase;
      if (error != null) {
        // Collapsible for the same reason the draft account is: a render
        // failure names the path, the errno and two next steps, which is four
        // lines the panel's viewport does not have. Cut at a word with the
        // control that opens it inside the alert, rather than at the fold with
        // nothing.
        children.add(
          _DarkroomCollapsibleAlert(
            tone: BannerTone.error,
            title: 'The render did not finish',
            disclosureObject: 'why the render did not finish',
            message: error,
          ),
        );
      } else if (cancelled != null) {
        children.add(
          SkotiqBanner(
            title: 'The render was stopped',
            tone: BannerTone.info,
            message:
                'You stopped the render during $cancelled. The picture above '
                'is the one before it.',
          ),
        );
      } else {
        children.add(
          Text(
            state.preview == null
                ? 'Nothing has been rendered yet.'
                : 'Up to date with the stack.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        );
      }
      // Before the button, not after it: this is part of the account of what
      // the last render did, and every row it sits below is a row that can
      // push it past the fold of a fixed-height panel.
      //
      // It is stated only when the stack carries a step that reads it — one
      // with no pinned scales that does not balance on the field's stars. The
      // catalogue is lent to `color_calibrate` and to nothing else, so on a
      // stack without that step — an autopilot draft of a mono master, a recipe
      // with no steps at all — this alert reports the absence of something no
      // step was going to use, in the panel's most prominent slot.
      final photometryNote = state.photometryNote;
      if (photometryNote != null && state.colorCalibrateReadsCatalog) {
        children
          ..add(const SizedBox(height: SkotiqTokens.spaceSm))
          ..add(
            SkotiqBanner(
              tone: BannerTone.info,
              title: 'Color calibration has no catalogue stars',
              message: photometryNote,
            ),
          );
      }
      children
        ..add(const SizedBox(height: SkotiqTokens.spaceSm))
        ..add(
          SkotiqButton(
            label: 'Render again',
            icon: SkotiqIcons.refresh,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => widget.onRerender(),
          ),
        );
    }

    if (state.savePending) {
      children
        ..add(const SizedBox(height: SkotiqTokens.spaceSm))
        ..add(
          Text(
            'Saving this edit to the recipe…',
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.textMuted,
            ),
          ),
        );
    }
    final saveError = state.saveError;
    if (saveError != null) {
      children
        ..add(const SizedBox(height: SkotiqTokens.spaceSm))
        ..add(
          SkotiqBanner(
            title: 'The recipe was not saved',
            tone: BannerTone.error,
            message: saveError,
          ),
        );
    }

    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}
