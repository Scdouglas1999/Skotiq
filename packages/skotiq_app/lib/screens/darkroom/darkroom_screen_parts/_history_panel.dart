part of '../darkroom_screen.dart';

/// The recipe as an ordered list of step cards.
///
/// Each card carries three separate statements about its step and never lets
/// one stand in for another:
///
///  * what the recipe says — the operation, its version, its stage, and whether
///    it is switched on;
///  * what `validate` says — whether this build registers the operation and
///    whether its parameters are inside their documented ranges;
///  * what the last render DID — applied, off, or skipped with the operation's
///    own reason. A skip reason is always on the card, never behind the
///    expander: `color_calibrate` skipping for want of a catalogue is an
///    explanation the operator has to read, not a failure to hunt for.
class _DarkroomHistoryPanel extends StatefulWidget {
  final DarkroomState state;
  final void Function(int index) onToggle;
  final void Function(int index, String name, Object? value) onParamChanged;

  /// Takes the step out of the recipe. Journalled, so Undo restores it.
  final void Function(int index) onRemove;

  /// Asks the engine whether the candidate order is legal and, when it is,
  /// commits it. Answers false when the move was refused.
  final Future<bool> Function(int oldIndex, int newIndex) onReorder;

  /// Puts a step for the chosen operation into the stack. Answers false when
  /// nothing was added, with the reason on the state.
  final Future<bool> Function(DarkroomOpSpec op) onInsert;

  const _DarkroomHistoryPanel({
    required this.state,
    required this.onToggle,
    required this.onParamChanged,
    required this.onRemove,
    required this.onReorder,
    required this.onInsert,
  });

  @override
  State<_DarkroomHistoryPanel> createState() => _DarkroomHistoryPanelState();
}

class _DarkroomHistoryPanelState extends State<_DarkroomHistoryPanel> {
  /// Which cards have their parameter controls open, by position in the stack.
  final Set<int> _expanded = <int>{};

  /// Bumped every time the stack's ORDER changes, and carried in every card's
  /// key so that an order change rebuilds all of them rather than only the ones
  /// that moved.
  ///
  /// Measured on the release bundle 2026-08-31: `ReorderableListView` builds its
  /// items through a `SliverChildBuilderDelegate`, which cannot adopt a
  /// locally-keyed element at a new index — so a move re-inflates the cards that
  /// changed position and leaves the ones that did not. Their accessibility
  /// nodes follow: the moved cards get new node ids, the unmoved ones keep
  /// theirs. Flutter publishes the correct traversal order either way, but the
  /// Linux AT-SPI bridge keeps the child nodes it already holds where they are
  /// and appends the new ones after them — so moving the first
  /// step of `[Background extract, Denoise, Stretch]` down published
  /// `Stretch, Denoise, Background extract`: the one card that survived the
  /// rebuild, first, then the two that were rebuilt. A reader was walked
  /// through the pipeline in an order that contradicted both the picture and
  /// the "1 of 3" each card states.
  ///
  /// With the generation in the key no card survives an order change, so the
  /// bridge has nothing to keep in place and builds the list in the order it
  /// was handed. A parameter edit does not touch the order and so does not
  /// touch the generation — the card keeps its element, and with it the drag
  /// recognizer of whichever slider is being held.
  int _orderGeneration = 0;

  @override
  void didUpdateWidget(covariant _DarkroomHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameOrder(oldWidget.state.steps, widget.state.steps)) {
      _orderGeneration++;
    }
  }

  /// Whether the two stacks are the same steps in the same places.
  ///
  /// Compared by IDENTITY, which is what the card keys join on: an edit that
  /// rewrites a step's parameters produces a new immutable value carrying the
  /// same identity, and that is not an order change.
  static bool _sameOrder(List<DarkroomStep> before, List<DarkroomStep> after) {
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      if (!identical(before[i].identity, after[i].identity)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final state = widget.state;
    final steps = state.steps;

    // The alerts ride INSIDE the scrolling region rather than above it. They
    // carry sentences the engine wrote, so their height is not this screen's to
    // predict: a long refusal in a short panel used to push the Column past its
    // own box, and Flutter renders that as a striped overflow bar over text
    // nobody can scroll to.
    final alerts = _alerts(state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Inset to the same gutter the step cards and the alerts below use.
        // SectionHeader pads vertically only, and on the phone's segmented
        // layout this panel IS the screen — nothing outside it supplies a
        // margin, so without this the heading and its subtitle start at the
        // window edge while every card under them is indented.
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceMd,
          ),
          child: SectionTitle(
            icon: SkotiqIcons.layers,
            title: 'History stack',
            // In the heading, outside the scrolling region: the one control
            // that gets an operation INTO the stack is then on screen whether
            // the stack is empty or forty cards deep, and it costs the cards
            // no height — a row of its own pushed the last card out of a
            // short panel.
            trailing: _DarkroomAddStep(state: state, onInsert: widget.onInsert),
          ),
        ),
        Expanded(
          child: steps.isEmpty
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ...alerts,
                      const EmptyState.compact(
                        icon: SkotiqIcons.layers,
                        title: 'Nothing interpreted yet',
                        body: 'This recipe carries no operations, so the '
                            'viewport is the linear master itself. "Add '
                            'step", above, lists every operation this build '
                            'registers and puts the first one in.',
                      ),
                    ],
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
                  itemCount: steps.length,
                  buildDefaultDragHandles: false,
                  header: alerts.isEmpty
                      ? null
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: alerts,
                        ),
                  // The move is not committed until the engine has accepted the
                  // resulting order, so the list snaps back for the frame the
                  // check takes and then rebuilds in the new order. A move the
                  // engine refuses therefore never appears to have happened.
                  //
                  // onReorderItem, not onReorder: it reports the destination
                  // already adjusted for the removal, which is the index the
                  // controller inserts at.
                  //
                  // The list callback is synchronous, so the answer is read off
                  // the state the controller publishes rather than awaited
                  // here; the controller states every refusal on that state and
                  // throws nothing, so `unawaited` drops a verdict this widget
                  // has no other use for, not an error.
                  onReorderItem: (oldIndex, newIndex) {
                    unawaited(widget.onReorder(oldIndex, newIndex));
                  },
                  itemBuilder: (context, index) =>
                      _card(context, colors, state, index),
                ),
        ),
      ],
    );
  }

  /// What the engine said about the stack as a whole, above the cards.
  ///
  /// No gutter of their own: every caller places them inside a region that
  /// already carries the step cards' padding, so an alert lines up with the
  /// cards it is about.
  List<Widget> _alerts(DarkroomState state) {
    Widget wrap(Widget alert) => Padding(
          padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
          child: alert,
        );
    return [
      // The engine's whole-stack refusal, and only while it is about a step the
      // render will actually replay: a refusal naming a step the operator has
      // already switched off describes a recipe that is not the one being
      // rendered. The switched-off step keeps its own warning on its own card.
      if (state.blockingRecipeError != null)
        wrap(
          SkotiqBanner(
            tone: BannerTone.error,
            title: 'This stack does not validate',
            message: state.blockingRecipeError!,
          ),
        ),
      if (state.catalogError != null)
        wrap(
          SkotiqBanner(
            title: 'The operation catalogue could not be read',
            tone: BannerTone.warning,
            message: state.catalogError!,
          ),
        ),
      // A refused move snaps the card back to where it started, which on its
      // own looks like a dropped gesture. The engine's own sentence stays on
      // the panel — beside the stack it is about — until the next edit clears
      // it, rather than only flashing past in a toast.
      if (state.reorderRefusal != null)
        wrap(
          SkotiqBanner(
            tone: BannerTone.warning,
            title: 'That move was refused',
            message: state.reorderRefusal!,
          ),
        ),
      // An insert that added nothing closes its chooser and leaves the stack
      // exactly as it was, which on its own is indistinguishable from a
      // control that does nothing. The refusal — the engine's sentence, or the
      // registry's own note about a master it could not measure — stays beside
      // the stack until the next edit clears it.
      if (state.insertRefusal != null)
        wrap(
          SkotiqBanner(
            key: const ValueKey('darkroom_insert_refusal'),
            tone: BannerTone.warning,
            title: 'That step was not added',
            message: state.insertRefusal!,
          ),
        ),
    ];
  }

  Widget _card(
    BuildContext context,
    SkotiqColors colors,
    DarkroomState state,
    int index,
  ) {
    final step = state.steps[index];
    final spec = state.catalog?.specFor(step);
    final report = state.reportFor(index);
    final issue = state.issueFor(index);
    final omitted = state.isOmittedFromRender(index);
    final expanded = _expanded.contains(index);
    final title = darkroomOpTitle(step.opId);

    return Padding(
      // Keyed on the step's IDENTITY, which moves with it on a reorder and
      // survives every edit to it. Keying on the step value instead re-keyed the
      // card on every parameter change — each change builds a new immutable
      // step — which tore the card's element down and disposed the drag
      // recognizer of whichever slider was being held: a slider took the value
      // under the pointer when it went down and then ignored the rest of the
      // gesture.
      //
      // The generation rides alongside it so that an ORDER change re-keys every
      // card at once; [_orderGeneration] says why the reading order needs that.
      key: ValueKey((_orderGeneration, step.identity)),
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      // The card's POSITION IN THE STACK, stated to assistive tech rather than
      // left to be inferred from where the card happens to be painted.
      //
      // Without it a reader is walked through the stack in an order that is not
      // the pipeline's: after a committed reorder, AT-SPI read crop, stretch,
      // denoise, background extract over a recipe the panel painted — and the
      // engine ran — as crop, denoise, background extract, stretch.
      //
      // Sibling nodes with no sort key are ordered by their RECTANGLES, and
      // that order reaches the bridge only on a frame where the enclosing list
      // node is itself dirty (`SemanticsOwner.sendSemanticsUpdate` re-states
      // `childrenInTraversalOrder` for dirty nodes only), so the last order
      // assistive tech is handed is whatever geometry said on that frame —
      // while the cards were still moving, or while the ones off the end of the
      // viewport were clipped to the same edge. The ordinal is read off the
      // recipe instead, so every frame states the order the engine will run.
      child: Semantics(
        sortKey: OrdinalSortKey(index.toDouble()),
        child: SkotiqPanel(
          padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: Semantics(
                      label: 'Reorder $title',
                      child: Padding(
                        padding: const EdgeInsets.only(
                          right: SkotiqTokens.spaceSm,
                        ),
                        child: Icon(
                          SkotiqIcons.move,
                          size: SkotiqTokens.iconSm,
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                  ),
                  // The drag handle is the only thing that moved a step, and a
                  // press-and-drag cannot be performed from a keyboard or from
                  // assistive tech: the handle publishes a panel with no action,
                  // so a walk of this stack found four "Reorder <op>" panels and
                  // no way to reorder anything. These are the same move, as two
                  // ordinary buttons.
                  _moveButton(
                    state: state,
                    title: title,
                    index: index,
                    up: true,
                  ),
                  _moveButton(
                    state: state,
                    title: title,
                    index: index,
                    up: false,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: SkotiqTypography.labelStrong.copyWith(
                            color: step.enabled
                                ? colors.textPrimary
                                : colors.textMuted,
                          ),
                        ),
                        const SizedBox(height: SkotiqTokens.spaceXs),
                        Wrap(
                          spacing: SkotiqTokens.spaceXs,
                          runSpacing: SkotiqTokens.spaceXs,
                          children: [
                            _DarkroomTag(
                              label: 'v${step.opVersion}',
                              tooltip:
                                  'The operation version this recipe was written '
                                  'with. A recipe keeps rendering with its own '
                                  'version, so improving an operation never '
                                  'changes an existing recipe.',
                            ),
                            if (spec != null)
                              _DarkroomTag(
                                label: spec.stage.label,
                                tooltip: _stageTooltip(spec),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // container, not a bare annotation: without a node of its own
                  // the switch's toggle state and tap action are absorbed by the
                  // card's own node, and the whole card — the reorder label, the
                  // title, the version, the outcome line, the paragraph
                  // explaining the unregistered operation — becomes ONE
                  // ~200-character togglable control with no distinct switch.
                  // That happened exactly on the cards that had no second
                  // control to force a split, which is to say on the error case.
                  Semantics(
                    container: true,
                    label: '$title enabled',
                    child: SkotiqSwitch(
                      value: step.enabled,
                      compact: true,
                      onChanged: (_) => widget.onToggle(index),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              _outcomeLine(colors, state, step, report, omitted, index),
              if (report?.reason != null) ...[
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  report!.reason!,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
              if (issue != null && !issue.isClean) ...[
                const SizedBox(height: SkotiqTokens.spaceSm),
                SkotiqBanner(
                  title: 'This step will not run',
                  tone: BannerTone.error,
                  message: _issueMessage(step, issue),
                ),
              ],
              if (spec == null && state.catalog != null) ...[
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  'This build registers no ${step.opId}@${step.opVersion}, so '
                  'its parameters have no documented ranges to draw controls '
                  'from. The stored values are left exactly as they are.',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: SkotiqTokens.spaceSm),
              _cardActions(title, spec, expanded, index),
              if (expanded && spec != null) ...[
                const SizedBox(height: SkotiqTokens.spaceSm),
                for (final param in spec.params)
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: SkotiqTokens.spaceMd,
                    ),
                    child: _paramControl(colors, index, step, param),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// One end of the keyboard-reachable reorder.
  ///
  /// The destination is the index the step lands at once it has been lifted out
  /// of the list — the same index [_DarkroomHistoryPanel.onReorder] takes from
  /// the drag — so moving up is `index - 1` and moving down is `index + 1`.
  ///
  /// At the ends the control is DISABLED and says which end it is at, rather
  /// than being dropped: a card that loses a control the card above it has
  /// makes the two read as different kinds of card. The controller clamps an
  /// out-of-range destination back onto the step's own index, so an enabled
  /// control at an end would be a button that does nothing.
  ///
  /// A destination the STAGE RULE forbids disables it the same way, for the
  /// same reason. Gated on the ends alone, `Move Denoise down` over
  /// `[Crop, Background extract, Denoise, Stretch]` published itself as live
  /// for a move whose only destination is past the stretch — the engine
  /// refused it after the tap, every time, from a control that had advertised
  /// nothing. [_stageOrderObjection] answers before the press; the controller
  /// still asks the engine before it commits, so the post-press refusal stays
  /// as the backstop for everything this build cannot decide from the
  /// catalogue.
  Widget _moveButton({
    required DarkroomState state,
    required String title,
    required int index,
    required bool up,
  }) {
    final stepCount = state.steps.length;
    final direction = up ? 'up' : 'down';
    final position = '${index + 1} of $stepCount';
    final destination = up ? index - 1 : index + 1;
    final String? reason;
    if (destination < 0 || destination >= stepCount) {
      reason =
          'it is already ${up ? 'first' : 'last'} in the stack ($position)';
    } else {
      final objection = _stageOrderObjection(state, index, destination);
      reason = objection == null
          ? null
          : 'the stage rule refuses that order: $objection';
    }
    final enabled = reason == null;
    final label =
        enabled ? 'Move $title $direction' : 'Move $title $direction — $reason';
    void move() {
      unawaited(widget.onReorder(index, up ? index - 1 : index + 1));
    }

    // The name goes on the ICON, not on a Semantics wrapper around the button.
    // `IconButton` publishes its own node — role, enabled state, focusability
    // and the tap — and a wrapper that excludes it publishes a NAMED node that
    // is not the one the keyboard lands on: measured on the release bundle
    // 2026-08-31, `button: 'Move Denoise up'` carried `enabled` and no
    // `focusable`, and a Tab walk of one step card stopped on unnamed panels
    // for both move buttons while only the enable toggle announced itself.
    // `Icon.semanticLabel` is a child fragment, so it merges INTO the button's
    // own node and the whole control is one named, focusable, tappable node.
    // The tooltip stays for the pointer; it reaches assistive tech as the
    // node's description rather than as its name.
    return IconButton(
      icon: Icon(
        up ? SkotiqIcons.arrowUp : SkotiqIcons.arrowDown,
        size: SkotiqTokens.iconSm,
        semanticLabel: label,
      ),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      tooltip: label,
      onPressed: enabled ? move : null,
    );
  }

  /// The stage rule's objection to moving the step at [from] to [to], or null
  /// when it has none — and null as well when this build cannot tell.
  ///
  /// Null when the stack as it STANDS already breaks the rule: an order that is
  /// refused however it is arranged is not this move's doing, and disabling on
  /// it would take away the very moves that fix it while blaming the control
  /// for a violation it did not make. The engine's post-commit refusal covers
  /// that case, as it covers every other reason a `validate` can fail.
  String? _stageOrderObjection(DarkroomState state, int from, int to) {
    final steps = state.steps;
    if (_stageOrderViolation(state, steps) != null) return null;
    final candidate = List<DarkroomStep>.from(steps);
    candidate.insert(to, candidate.removeAt(from));
    return _stageOrderViolation(state, candidate);
  }

  /// Where [steps] breaks the engine's stage rule, in the words the control
  /// states, or null when it does not.
  ///
  /// This is `recipe/render.rs`'s `validate` loop as the app models it — the
  /// same rule [DarkroomState.insertIndexFor] places a new step by: walk the
  /// stack in order, remember the first stretched-stage step, and object to the
  /// first linear-stage step that comes after it. A step whose operation this
  /// build does not register, or whose stage the registry names and this build
  /// does not model, carries no stage into the rule and none is invented for
  /// it.
  ///
  /// The engine stays the authority. This decides what a control ADVERTISES;
  /// `darkroom_controller`'s reorder path still asks `validate` about the whole
  /// candidate stack before it commits, and states whatever comes back.
  ///
  /// The step numbers count the order they were handed, from 1, the way the
  /// engine's own sentences and the cards on screen do — so a caller that
  /// passes a candidate order says so, as `_refusalOverCandidate` does.
  String? _stageOrderViolation(DarkroomState state, List<DarkroomStep> steps) {
    int? stretchedAt;
    for (var i = 0; i < steps.length; i++) {
      final stage = state.catalog?.specFor(steps[i])?.stage;
      if (stage == DarkroomOpStage.stretched) {
        stretchedAt ??= i;
      } else if (stage == DarkroomOpStage.linear && stretchedAt != null) {
        return 'step ${i + 1} (${darkroomOpTitle(steps[i].opId)}) would be a '
            'linear-stage operation running after step ${stretchedAt + 1} '
            '(${darkroomOpTitle(steps[stretchedAt].opId)}), which has already '
            'left the linear stage. Those positions count the order the move '
            'would produce, from 1 — not the stack on screen';
      }
    }
    return null;
  }

  /// The row of controls every card carries.
  ///
  /// "Remove" is on every card, not only on the ones this build cannot run: a
  /// step is data the operator owns, and an editor that can add and disable but
  /// never delete leaves a stack no route back to the one it started as. On a
  /// card whose operation is unregistered it is the only control that acts on
  /// what that card says — switching such a step off keeps it out of the render,
  /// but the recipe still names an operation nothing here can replay.
  Widget _cardActions(
    String title,
    DarkroomOpSpec? spec,
    bool expanded,
    int index,
  ) {
    final hasParams = spec != null && spec.params.isNotEmpty;
    // Wrap, not Row: the panel is resizable down to 280 logical pixels and the
    // two labels grow with the operation name, so on a narrow panel they stack
    // instead of overflowing. spaceBetween keeps the destructive one away from
    // the expander whenever both fit on one line.
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceXs,
      children: [
        if (hasParams) _expandToggle(title, expanded, index),
        _DarkroomNamedControl(
          // Qualified, because a screen reader reads this card's controls in a
          // list of identical ones: four bare "Remove" buttons name no step.
          label: 'Remove $title',
          onPressed: () => widget.onRemove(index),
          child: SkotiqButton(
            label: 'Remove',
            icon: SkotiqIcons.delete,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => widget.onRemove(index),
          ),
        ),
      ],
    );
  }

  String _stageTooltip(DarkroomOpSpec spec) {
    switch (spec.stage) {
      case DarkroomOpStage.linear:
        return 'Emits linear pixels, so it has to run before the stretch. '
            'Dragging it below a stretched step is refused.';
      case DarkroomOpStage.stretched:
        return 'Emits stretched (display-domain) pixels. Everything after it '
            'works on the stretched image.';
      case DarkroomOpStage.unmodelled:
        return 'The registry names this operation\'s stage as '
            '"${spec.stageWire}", which this build does not model, so the '
            'ordering rule for it is whatever the engine says at validation.';
    }
  }

  String _issueMessage(DarkroomStep step, DarkroomStepIssue issue) {
    final engineMessage = issue.error;
    if (!issue.registered) {
      final latest = issue.latestVersion;
      final suffix = latest == null
          ? ''
          : ' The newest version this build registers is v$latest.';
      return 'This build registers no ${step.opId}@${step.opVersion}, so the '
          'render cannot run it.$suffix';
    }
    if (engineMessage != null) return engineMessage;
    return 'The engine refused this step without naming a reason.';
  }

  /// What the last render DID with this step, and nothing else.
  ///
  /// Every one of these labels comes from a line the engine wrote about this
  /// exact step, or says that no such line exists. Nothing here infers an
  /// outcome from the step itself: a stack whose render failed, or which was
  /// edited since the last one, has no outcomes to show, and saying so is the
  /// only honest thing left — a badge that carried the previous render's verdict
  /// forward is how a step this build cannot even run came to read "Applied by
  /// the last render".
  Widget _outcomeLine(
    SkotiqColors colors,
    DarkroomState state,
    DarkroomStep step,
    DarkroomStepReport? report,
    bool omitted,
    int index,
  ) {
    final IconData icon;
    final Color tint;
    final String label;
    switch (report?.outcome) {
      case DarkroomStepOutcome.applied:
        final clampNote = _cropClampNote(report);
        if (clampNote != null) {
          // Applied, but not as written: the engine measured an adjustment
          // (crop's rectangle did not fit this master) and said so in the
          // report. Plain green "Applied" over that measurement would carry
          // the recipe's numbers as if they had run.
          icon = SkotiqIcons.info;
          tint = colors.warning;
          label = clampNote;
        } else {
          icon = SkotiqIcons.check;
          tint = colors.success;
          label = 'Applied by the last render';
        }
      case DarkroomStepOutcome.disabled:
        icon = SkotiqIcons.hidden;
        tint = colors.textMuted;
        label = 'Off — the render skipped it';
      case DarkroomStepOutcome.skipped:
        icon = SkotiqIcons.info;
        tint = colors.warning;
        label = 'Skipped, and here is why';
      case DarkroomStepOutcome.unreported:
        icon = SkotiqIcons.help;
        tint = colors.textMuted;
        label = 'The last render reported nothing for this step';
      case null:
        if (omitted) {
          icon = SkotiqIcons.hidden;
          tint = colors.textMuted;
          label = 'Off, and left out of the render — this build cannot run it';
        } else if (state.failureReasonFor(index) case final reason?) {
          // The card of the step the failure NAMED. It used to carry the same
          // "nothing is reported for this step" sentence as every step that
          // merely never ran, so the banner named a culprit precisely and the
          // stack marked none of its four cards — leaving the operator to count
          // steps against a number the engine wrote about a different list.
          icon = SkotiqIcons.imageOff;
          tint = colors.error;
          label = 'This step failed the render: $reason';
        } else if (state.renderError != null) {
          icon = SkotiqIcons.help;
          tint = colors.textMuted;
          label = 'The last render did not finish, so nothing is reported for '
              'this step';
        } else if (state.rendering) {
          icon = SkotiqIcons.help;
          tint = colors.textMuted;
          label = 'Rendering — no outcome for this step yet';
        } else {
          icon = SkotiqIcons.help;
          tint = colors.textMuted;
          label = step.enabled
              ? 'Not rendered yet'
              : 'Off — nothing has rendered it';
        }
    }
    // Icon AND words, never colour alone: under the red-night palette success,
    // warning and error are all reds, so a badge that carried its meaning in
    // its fill would say nothing at the telescope.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: SkotiqTokens.iconXs, color: tint),
        const SizedBox(width: SkotiqTokens.spaceXs),
        Expanded(
          child: Text(
            label,
            style: SkotiqTypography.captionSm.copyWith(color: tint),
          ),
        ),
      ],
    );
  }

  /// The adjustment sentence for a crop the render clamped, or null.
  ///
  /// The engine publishes `clampedToImage` only when the intersection did real
  /// work (past the one-pixel scale rounding), so a note here always reflects
  /// a rectangle that genuinely reached past the frame. The sentence quotes
  /// the recipe's own numbers; the measurement's `requested`/`applied` rects
  /// are render-level pixels, and quoting them beside master coordinates
  /// would misstate one or the other.
  String? _cropClampNote(DarkroomStepReport? report) {
    final clamp = report?.measured?['clampedToImage'];
    if (clamp is! Map<String, dynamic>) return null;
    final rect = clamp['recipeRect'];
    if (rect is! Map<String, dynamic>) {
      return 'Applied, adjusted to fit: the rectangle reaches past this '
          "master's edge, so the render applied only the part inside the "
          'frame';
    }
    return 'Applied, adjusted to fit: the crop asks for '
        '${rect['width']}×${rect['height']} at '
        '(${rect['x']}, ${rect['y']}), which reaches past this '
        "master's edge — the render applied only the part inside the "
        'frame';
  }

  /// The parameters expander.
  ///
  /// The button READS "Parameters" — inside the Crop card, in a column of Crop's
  /// own controls, the operation's name on the button would be noise. Its
  /// ACCESSIBLE name is qualified, because a screen-reader walk of the stack has
  /// no column to read it in: four sibling nodes all announcing "Parameters,
  /// button" say nothing about which operation each one opens.
  Widget _expandToggle(String title, bool expanded, int index) {
    void toggle() => setState(() {
          if (expanded) {
            _expanded.remove(index);
          } else {
            _expanded.add(index);
          }
        });
    return _DarkroomNamedControl(
      label: expanded ? 'Hide $title parameters' : '$title parameters',
      onPressed: toggle,
      child: SkotiqButton(
        label: expanded ? 'Hide parameters' : 'Parameters',
        icon: expanded ? SkotiqIcons.chevronUp : SkotiqIcons.chevronDown,
        variant: ButtonVariant.ghost,
        size: ButtonSize.small,
        onPressed: toggle,
      ),
    );
  }

  // -------------------------------------------------------------------
  // Parameter controls
  // -------------------------------------------------------------------

  /// One control per registry-documented parameter.
  ///
  /// The registry owns the type, the range and the default; nothing here
  /// invents a bound. A parameter whose key is absent from the step renders the
  /// operation's own default and says so, and the key is written only when the
  /// operator moves the control — so improving a default still reaches recipes
  /// that never overrode it.
  Widget _paramControl(
    SkotiqColors colors,
    int index,
    DarkroomStep step,
    DarkroomParamSpec spec,
  ) {
    final present = step.params.containsKey(spec.name);
    final effective = present ? step.params[spec.name] : spec.defaultValue;

    final Widget control;
    switch (spec.kind) {
      case DarkroomParamKind.number:
      case DarkroomParamKind.integer:
        control = _numberControl(colors, index, step, spec, effective);
      case DarkroomParamKind.enumerated:
        control = SkotiqDropdown(
          value: effective is String && spec.allowed.contains(effective)
              ? effective
              : null,
          hint: 'Choose ${spec.name}',
          items: spec.allowed,
          isExpanded: true,
          onChanged: (value) => widget.onParamChanged(index, spec.name, value),
        );
      case DarkroomParamKind.numberArray:
        control = _arrayControl(colors, index, step, spec, effective);
      case DarkroomParamKind.boolean:
        control = Align(
          alignment: Alignment.centerLeft,
          child: SkotiqSwitch(
            value: effective == true,
            onChanged: (value) =>
                widget.onParamChanged(index, spec.name, value),
          ),
        );
      case DarkroomParamKind.object:
        control = _measuredValue(colors, spec, effective);
      case DarkroomParamKind.numberList:
      case DarkroomParamKind.unrepresented:
        control = _readOnlyValue(colors, spec, effective);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              // The registry's display name, with the unit it states. The wire
              // key rides in the tooltip rather than on the label: `d`, `b` and
              // `symmetryPoint` are the engine's own field names, and a control
              // labelled with one asks the operator to know them — while a
              // stored recipe is still read in those keys, so they cannot
              // simply be dropped.
              child: Tooltip(
                message: spec.displayName == spec.name
                    ? spec.name
                    : '${spec.displayName} — stored in this recipe as '
                        '"${spec.name}"',
                child: Text(
                  spec.displayName,
                  style: SkotiqTypography.labelSm.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
            if (!present)
              _DarkroomTag(
                label: 'default',
                tooltip: 'This recipe stores no value for "${spec.name}", so '
                    'the operation reads its own documented default. Moving '
                    'the control writes a value; clearing it hands the '
                    'parameter back to the operation.',
              )
            else if (spec.defaultValue != null)
              _DarkroomNamedControl(
                // Qualified for the same reason "Remove" is: a card with four
                // parameters publishes four sibling nodes, and "Use default"
                // said three words that name none of them. Reading order is
                // not a name.
                label: 'Use default for ${spec.displayName}',
                onPressed: () => widget.onParamChanged(index, spec.name, null),
                child: SkotiqButton(
                  label: 'Use default',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: () =>
                      widget.onParamChanged(index, spec.name, null),
                ),
              ),
          ],
        ),
        if (spec.summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
            child: Text(
              spec.summary,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        if (!spec.independent && spec.kind != DarkroomParamKind.object)
          Padding(
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
            child: Text(
              'Constrained together with another parameter of this step, so a '
              'value inside its own range can still be refused.',
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textMuted,
              ),
            ),
          ),
        control,
      ],
    );
  }

  Widget _numberControl(
    SkotiqColors colors,
    int index,
    DarkroomStep step,
    DarkroomParamSpec spec,
    Object? effective,
  ) {
    final isInteger = spec.kind == DarkroomParamKind.integer;
    final value = darkroomNumber(effective);
    final min = spec.min;
    final max = spec.max;
    final span = min != null && max != null ? max - min : null;
    // An integer parameter carries one slider division per integer it can
    // reach, so the rounded span IS the division count; null leaves the track
    // continuous. Computed here, once, so the count the track is built with is
    // the same one the degenerate case below is judged on.
    final divisions =
        isInteger && span != null && span <= 64 ? span.round() : null;

    if (spec.isSliderRanged &&
        value != null &&
        min != null &&
        max != null &&
        span != null &&
        // A range narrower than a single integer step — min 1.0, max 1.4, say
        // — rounds to ZERO divisions, which a Material slider rejects outright
        // (an assert in debug, NaN track geometry and a 0 nudge step in
        // release) and which holds at most one selectable integer anyway. That
        // is not a slider: it falls through to the typed field below, where
        // the one legal value is still read and re-entered.
        divisions != 0) {
      final clamped = value.clamp(min, max);
      void write(double raw) => widget.onParamChanged(
            index,
            spec.name,
            isInteger ? raw.round() : raw,
          );
      // What one assistive-tech increment moves: one division when the range is
      // divided, a tenth of the span otherwise — the same unit the framework's
      // own slider semantics use.
      final step =
          divisions != null && divisions > 0 ? span / divisions : span / 10;
      // The THUMB is clamped, because the Material slider refuses a position
      // outside its own track. The READING is not: the recipe holds whatever
      // was typed into the Exact field, the engine refuses the step for it by
      // name and number, and a slider announcing the clamp reports a value the
      // engine never received. Measured on the release bundle 2026-08-31: with
      // `scaleCount` = 500 stored and the card reading "denoise@1: parameter
      // 'scaleCount' = 500 is outside [1, 6]", the slider announced 6.
      final reading = _darkroomNumberReading(value, isInteger: isInteger);
      final outOfRange = value < min || value > max;
      final announced = outOfRange
          ? '$reading — outside the accepted range, so the render refuses this '
              'step'
          : reading;
      return Row(
        children: [
          Expanded(
            // The slider is this screen's primary editing control and it
            // published NOTHING useful: three sibling sliders inside one card
            // came back with an empty name and a percentage for a value, so a
            // screen-reader walk heard "slider" three times and could not tell
            // which parameter it was on or what it was set to. The name and the
            // value are on screen — a label above the track, a readout beside
            // it — and both were sighted-only.
            //
            // MERGED, not excluded and not a second node. The framework's
            // slider is its own semantics boundary: an annotation over it
            // publishes a second node, and excluding it publishes no node at
            // all — measured, both of them, on this build. Merging keeps the
            // slider's own node — its role, its increase and decrease actions,
            // its focusability — and lends it the name and the reading it was
            // missing.
            //
            // The value rides in the LABEL as well as in `value:` because the
            // Linux AT-SPI bridge publishes a node's name and description and
            // nothing else; the structured fields are for the bridges that
            // carry them.
            child: MergeSemantics(
              child: Semantics(
                label: '${_rangeLabel(spec)} — $announced',
                value: announced,
                // Where a nudge LANDS, which is measured from the thumb: an
                // increase from an out-of-range value moves to the end of the
                // track the engine accepts, not to 501.
                increasedValue: _darkroomNumberReading(
                  (clamped + step).clamp(min, max),
                  isInteger: isInteger,
                ),
                decreasedValue: _darkroomNumberReading(
                  (clamped - step).clamp(min, max),
                  isInteger: isInteger,
                ),
                child: SkotiqSlider(
                  value: clamped,
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: write,
                ),
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          // The readout is a FIELD, not a label. A slider spanning the whole
          // documented range cannot resolve a working region much narrower than
          // it: the stretch's intensity accepts 0…100 and the autopilot's own
          // measured value is 1.938, so one click a finger's width along the
          // track set 35.263 — an eighteen-fold change — and the render came
          // back a flat white field. The range shown is still the registry's
          // own; typing here is how the region between two pixels of travel is
          // reached, and how a value read off a previous recipe is put back
          // exactly.
          SizedBox(
            width: 116,
            child: _DarkroomNumberField(
              label: 'Exact',
              // Qualified for the same reason "Remove" and "Use default" are:
              // three slider-ranged parameters publish three sibling fields,
              // and a walk of one Stretch card heard "Exact, Exact, Exact".
              // Reading order is not a name — and the word on screen stays
              // "Exact" because the box is beside the slider it belongs to.
              semanticName: 'Exact value for ${spec.displayName}',
              value: value,
              onChanged: (parsed) => widget.onParamChanged(
                index,
                spec.name,
                parsed == null ? null : (isInteger ? parsed.round() : parsed),
              ),
            ),
          ),
        ],
      );
    }

    // The parameter's name is already printed above this control, twice over:
    // as the row's own title and inside the registry's summary of it. The
    // field carries the half of [_rangeLabel] that is NOT on screen yet — the
    // bounds — while its accessible name stays the whole thing, because
    // assistive tech reads this box out of the column that titles it.
    final bounds = _boundsLabel(spec);
    return _DarkroomNumberField(
      label: bounds.isEmpty ? null : bounds,
      semanticName: _rangeLabel(spec),
      value: value,
      onChanged: (parsed) => widget.onParamChanged(
        index,
        spec.name,
        parsed == null ? null : (isInteger ? parsed.round() : parsed),
      ),
    );
  }

  Widget _arrayControl(
    SkotiqColors colors,
    int index,
    DarkroomStep step,
    DarkroomParamSpec spec,
    Object? effective,
  ) {
    final length = spec.length;
    if (length == null || length <= 0) {
      return _readOnlyValue(colors, spec, effective);
    }
    final current = <double?>[
      for (var i = 0; i < length; i++)
        effective is List && i < effective.length
            ? darkroomNumber(effective[i])
            : null,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < length; i++) ...[
              if (i > 0) const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: _DarkroomNumberField(
                  label: '#${i + 1}',
                  semanticName: 'Value ${i + 1} of $length for '
                      '${spec.displayName}',
                  value: current[i],
                  onChanged: (parsed) {
                    final next = List<double?>.from(current);
                    next[i] = parsed;
                    // The operation validates the array as a whole, so a
                    // partly-typed array is held here rather than written as a
                    // value the operation would refuse.
                    if (next.any((v) => v == null)) return;
                    widget.onParamChanged(index, spec.name, [
                      for (final v in next) v!,
                    ]);
                  },
                ),
              ),
            ],
          ],
        ),
        if (current.any((v) => v == null))
          Padding(
            padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs),
            child: Text(
              'All $length values are needed before this parameter is written.',
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textMuted,
              ),
            ),
          ),
      ],
    );
  }

  /// A value this build draws no control for, shown as it is stored.
  ///
  /// The alternative — an invented control — would write values the operation
  /// may refuse, and a variable-length curve is edited with a curve editor
  /// rather than a row of boxes.
  /// A measured structured value, summarized in lines an operator can read:
  /// a color composite's masters and how each was registered, the common
  /// area, the flux matching.
  Widget _measuredValue(
    SkotiqColors colors,
    DarkroomParamSpec spec,
    Object? effective,
  ) {
    final lines = darkroomMeasuredValueLines(spec.name, effective);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: SkotiqTokens.borderRadiusSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in lines)
                Text(
                  line,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          'Measured when the draft was composed. Draft again to measure it '
          'again.',
          style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }

  Widget _readOnlyValue(
    SkotiqColors colors,
    DarkroomParamSpec spec,
    Object? effective,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: SkotiqTokens.borderRadiusSm,
          ),
          child: Text(
            effective == null ? 'no value stored' : '$effective',
            style: SkotiqTypography.monoSm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          'This build\'s editor draws no control for a "${spec.kindWire}" '
          'parameter, so the stored value is shown and left alone.',
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  /// The control's own name: what the parameter is called, and the bounds the
  /// registry accepts for it.
  ///
  /// The bounds are named as ACCEPTED bounds rather than printed bare. The
  /// stretch's points accept ±1e12 — the engine's limit, not a range any
  /// master's ADU occupies — and a bare "(-1.00e+12 … 1.00e+12)" beside a
  /// measured 529.74 reads as the range the operator is choosing within.
  static String _rangeLabel(DarkroomParamSpec spec) {
    final bounds = _boundsLabel(spec);
    if (bounds.isEmpty) return spec.displayName;
    return '${spec.displayName} ($bounds)';
  }

  /// The bounds alone, for the field that sits under a title already carrying
  /// the parameter's name.
  ///
  /// Empty when the registry states no floor or no ceiling: a field captioned
  /// with half a range would read as a bound the operation does not have.
  static String _boundsLabel(DarkroomParamSpec spec) {
    final min = spec.min;
    final max = spec.max;
    if (min == null || max == null) return '';
    if (min.abs() >= _kDarkroomGuardMagnitude &&
        max.abs() >= _kDarkroomGuardMagnitude) {
      if (min == -max) {
        return 'no practical limit; the engine refuses past '
            '±${_darkroomNumberReading(max)}';
      }
      return 'no practical limit; the engine refuses below '
          '${_darkroomNumberReading(min)} or above '
          '${_darkroomNumberReading(max)}';
    }
    return 'accepts ${_darkroomNumberReading(min)} … '
        '${_darkroomNumberReading(max)}';
  }
}

/// A design-system button under a name of this screen's choosing, published on
/// the SAME node the keyboard lands on.
///
/// Every control on a step card sits beside three identical ones, so its name
/// has to say which step or which parameter it acts on while the word on screen
/// stays short. The way that used to be done — `Semantics(label: …,
/// excludeSemantics: true)` around a [SkotiqButton] — publishes a correctly
/// named button that is NOT focusable: the focusable flag and the focus action
/// live on the button's own node, inside the subtree the exclusion drops.
/// Measured on the release bundle 2026-08-31, `button: 'Remove Denoise'` came
/// back as `['enabled', 'sensitive', 'showing']` with no `focusable`, and a Tab
/// walk of one step card stopped on four unnamed panels — reorder, parameters,
/// remove, use-default — while only the enable toggle, which is built as one
/// node, announced itself.
///
/// Dropping the exclusion is not the repair: [SkotiqButton] publishes its
/// own `label` AND the visible `Text` of that label, so merging announces
/// "Remove Denoise / Remove / Remove". (A bare button already reads its name
/// twice: the live tree carries `Duplicate as variant\nDuplicate as variant`.)
///
/// So the button keeps its own focus node — and with it its keyboard
/// activation and its focus ring — and this widget names the node that mirrors
/// it. The [Focus] here requests nothing of its own: it reports when the
/// control it wraps holds the focus, so the published `focused` flag is the
/// control's real state rather than an assertion, and [SemanticsProperties.
/// onFocus] hands assistive tech the same move by putting the focus on the
/// button's own node.
class _DarkroomNamedControl extends StatefulWidget {
  /// The name assistive tech reads for the whole control.
  final String label;

  /// What a press does. Null renders — and publishes — a disabled control.
  final VoidCallback? onPressed;

  /// The design-system control this names, drawn and operated as it always is.
  final Widget child;

  const _DarkroomNamedControl({
    required this.label,
    required this.onPressed,
    required this.child,
  });

  @override
  State<_DarkroomNamedControl> createState() => _DarkroomNamedControlState();
}

class _DarkroomNamedControlState extends State<_DarkroomNamedControl> {
  /// Watches the control's focus without competing for it: `canRequestFocus`
  /// false and `skipTraversal` true keep this node out of the tab order, so the
  /// control below still has exactly one stop.
  late final FocusNode _watcher = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    debugLabel: 'darkroom named control: ${widget.label}',
  );

  bool _focused = false;

  @override
  void dispose() {
    _watcher.dispose();
    super.dispose();
  }

  /// Puts the keyboard focus on the control this names.
  ///
  /// The focus goes to the control's OWN node — the one that activates on Enter
  /// and draws the focus ring — rather than to a node of this widget's, so a
  /// screen reader moving focus here leaves the app in the same state a Tab
  /// press would.
  void _takeFocus() {
    final reachable = _watcher.traversalDescendants;
    if (reachable.isNotEmpty) reachable.first.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      // Stated only while true. An explicit `false` reaches the Linux bridge as
      // a focusable disabled control, which is not what any other disabled
      // control in this app reports.
      focusable: enabled ? true : null,
      focused: _focused ? true : null,
      label: widget.label,
      onTap: widget.onPressed,
      onFocus: enabled ? _takeFocus : null,
      child: Focus(
        focusNode: _watcher,
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (has) {
          if (mounted && has != _focused) setState(() => _focused = has);
        },
        // The button's own annotation is dropped so that the node above carries
        // one name instead of three.
        child: ExcludeSemantics(child: widget.child),
      ),
    );
  }
}

/// Magnitude past which a stated bound is a guard rather than a range.
///
/// The stretch's black and white points are bounded at ±1e12 ADU, which is the
/// engine's limit on a nonsense number rather than a range any master's data
/// occupies: a 16-bit sensor's full scale is 65 535 ADU, so even summing ten
/// thousand of them stays under a billion. Printed bare, "accepts -1.00e+12 …
/// 1.00e+12" beside a measured black point of 529.751 reads as the range the
/// operator is choosing within.
const double _kDarkroomGuardMagnitude = 1e9;

/// How a number is READ OUT on this panel: three decimals for the values these
/// parameters actually take, exponent form only where a fixed-point reading
/// would be a wall of zeros.
///
/// One function for every reading the panel prints — slider readouts, the
/// bounds captions, and the numeric fields' resting text — so a value shown in
/// two places is shown the same way in both.
String _darkroomNumberReading(double value, {bool isInteger = false}) {
  if (isInteger) return value.round().toString();
  if (value == value.roundToDouble() && value.abs() < 1e6) {
    return value.toStringAsFixed(0);
  }
  if (value.abs() >= 1e6 || (value != 0 && value.abs() < 1e-3)) {
    return value.toStringAsExponential(2);
  }
  return value.toStringAsFixed(3);
}

/// A numeric field that follows the value it is given without fighting the
/// operator's cursor.
///
/// The controller is seeded once and re-seeded only when the box is not already
/// showing the incoming value — so an undo or a "use default" updates it, and
/// typing into it does not.
///
/// At rest the box READS the value the way every slider readout on the same
/// card does; focused, it shows the stored double in full. The box is both a
/// readout and an editor and the two jobs want different text: the autopilot's
/// measured black point is 529.7506799121094, and all seventeen digits echoed
/// into a 116-pixel box beside sliders that read to three decimals is noise,
/// while rounding what an EDIT starts from hands the recipe a number the
/// operator never chose. Switching form writes nothing: [onChanged] is the text
/// field's own, which fires on the operator's keystrokes and never on a
/// controller this widget seeds.
///
/// The words above the box and the name the box publishes are separate, because
/// they are read in different places. On screen the field sits under a title
/// that already names the parameter, so its caption carries only what that
/// title does not — "Exact", or the bounds. Assistive tech reads the box out of
/// that column, as one of several sibling fields inside one card, so its own
/// name has to be the qualified one.
class _DarkroomNumberField extends StatefulWidget {
  /// The caption above the box, or null when the row's title says everything a
  /// sighted reader needs.
  final String? label;

  /// The name assistive tech reads for the box itself, qualified by the
  /// parameter it edits.
  final String semanticName;

  final double? value;

  /// Called with the parsed number, or null when the box was emptied — which
  /// hands the parameter back to the operation's own default.
  final ValueChanged<double?> onChanged;

  const _DarkroomNumberField({
    required this.label,
    required this.semanticName,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_DarkroomNumberField> createState() => _DarkroomNumberFieldState();
}

class _DarkroomNumberFieldState extends State<_DarkroomNumberField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value == null ? '' : _text(widget.value!),
  );

  /// Owned here because the caption is drawn here: the design system's own
  /// field tints its caption while it has focus, and a caption this widget
  /// draws has to be given the same fact to follow.
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChanged);

  bool _unparseable = false;

  /// Swap the reading for the stored value, and back, as focus moves.
  ///
  /// Only while the box is still showing what it was given: text the operator
  /// has typed is theirs, and reformatting it under them — or reverting an
  /// unfinished entry the field is already refusing — would be this widget
  /// editing on their behalf.
  void _onFocusChanged() {
    if (!mounted) return;
    final value = widget.value;
    if (value != null && _showsValue(value)) {
      final text = _text(value);
      if (_controller.text != text) {
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant _DarkroomNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.value;
    if (!_showsValue(incoming)) {
      _controller.text = incoming == null ? '' : _text(incoming);
    }
  }

  /// Whether the box is showing [value] rather than something the operator has
  /// typed: either of the two forms it is drawn in, or any text that parses to
  /// it — which is what leaves a half-typed "529." alone.
  bool _showsValue(double? value) {
    final text = _controller.text.trim();
    if (double.tryParse(text) == value) return true;
    return value != null && text == _darkroomNumberReading(value);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  /// What the box shows for [value]: the stored double in full while the field
  /// is being edited, the panel's reading of it while it is not.
  String _text(double value) =>
      _focus.hasFocus ? _exact(value) : _darkroomNumberReading(value);

  /// Every digit the recipe holds. `toString` is what round-trips a double, so
  /// what the operator sees is what the row carries; whole values lose the
  /// trailing `.0` no astronomer types.
  static String _exact(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toStringAsFixed(0);
    }
    return '$value';
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final label = widget.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          // Excluded from semantics: the field below publishes the qualified
          // name, and a caption node beside it would announce the same control
          // twice under two different names.
          ExcludeSemantics(
            child: Text(
              label,
              style: SkotiqTypography.labelSm.copyWith(
                color: _focus.hasFocus ? colors.primary : colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
        ],
        Semantics(label: widget.semanticName, child: _field()),
      ],
    );
  }

  Widget _field() {
    return SkotiqTextField(
      focusNode: _focus,
      controller: _controller,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9eE.+\-]')),
      ],
      errorText: _unparseable ? 'Not a number' : null,
      onChanged: (raw) {
        final text = raw.trim();
        if (text.isEmpty) {
          if (_unparseable) setState(() => _unparseable = false);
          widget.onChanged(null);
          return;
        }
        final parsed = double.tryParse(text);
        if (parsed == null || !parsed.isFinite) {
          if (!_unparseable) setState(() => _unparseable = true);
          return;
        }
        if (_unparseable) setState(() => _unparseable = false);
        widget.onChanged(parsed);
      },
    );
  }
}
