part of '../darkroom_editor.dart';

/// The control that puts an operation into the recipe, and the chooser behind
/// it.
///
/// The editor's other edits all act on steps that are already in the stack:
/// toggle, reorder, remove, and the parameter controls. This is the one that
/// gets a step in — and without it "start from linear" produced a recipe that
/// could never carry an operation, while its own offer promised "nothing is
/// applied until you add a step".
///
/// Everything the chooser states about an operation comes from the registry's
/// published catalogue: its id, its version, the stage it emits, its summary,
/// and which of its parameters this build has no default for. Where the stack
/// or the engine leaves no room for an operation, the choice is DISABLED and
/// carries the reason — never hidden, because an operator looking for an
/// operation this build registers has to be able to see what is in the way.
class _DarkroomAddStep extends StatelessWidget {
  final DarkroomState state;

  /// Adds a step for the chosen operation. The controller asks the engine
  /// before anything commits, and states its refusal on the state.
  final Future<bool> Function(DarkroomOpSpec op) onInsert;

  const _DarkroomAddStep({required this.state, required this.onInsert});

  /// Why no operation can be added right now, or null when the chooser opens.
  ///
  /// The stack failing to validate is the case worth stating rather than
  /// silently allowing: the engine refuses a recipe as a WHOLE, so a step added
  /// to a stack it already refuses comes back refused for the fault that was
  /// there before — a refusal about a step the operator did not touch.
  String? get _blocked {
    if (!state.hasRecipe) {
      return 'No recipe is open, so there is no stack to add a step to.';
    }
    if (state.catalog == null) {
      final error = state.catalogError;
      return error ??
          'The operation catalogue has not been read from the engine yet, so '
              'the operations this build registers are not known here.';
    }
    final error = state.recipeError;
    if (error != null) {
      return 'The engine refuses this stack as it stands, so a step added to '
          'it would be refused with it: $error';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _blocked;
    final busy = state.insertBusy;
    final label = busy ? 'Adding the step…' : 'Add step';
    // The accessible name carries the refusal, because a disabled control that
    // says only "Add step" leaves the reason on screen for sighted readers and
    // nowhere else.
    final name = blocked == null ? label : 'Add step — $blocked';
    void open() => unawaited(_choose(context));
    return Semantics(
      container: true,
      button: true,
      enabled: blocked == null && !busy,
      label: name,
      excludeSemantics: true,
      onTap: blocked == null && !busy ? open : null,
      child: Tooltip(
        message: blocked ??
            'Choose an operation from the registry. It goes into the stack '
                'where the engine\'s stage rule leaves room for it, and the '
                'move controls on its card change that afterwards.',
        child: SkotiqButton(
          key: const ValueKey('darkroom_add_step'),
          label: label,
          icon: SkotiqIcons.add,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          isLoading: busy,
          onPressed: blocked == null && !busy ? open : null,
        ),
      ),
    );
  }

  Future<void> _choose(BuildContext context) async {
    final catalog = state.catalog;
    if (catalog == null || state.insertBusy) return;
    final chosen = await showDialog<DarkroomOpSpec>(
      context: context,
      builder: (dialogContext) => _DarkroomAddStepDialog(
        state: state,
        catalog: catalog,
      ),
    );
    if (chosen == null) return;
    await onInsert(chosen);
  }
}

/// The registry's operations, with what each one does and where it would go.
class _DarkroomAddStepDialog extends StatelessWidget {
  final DarkroomState state;
  final DarkroomCatalog catalog;

  const _DarkroomAddStepDialog({required this.state, required this.catalog});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqDialog(
      title: 'Add a step',
      icon: SkotiqIcons.add,
      width: 560,
      // The way out, in the footer — the shape every other dialog on this
      // screen takes, and the shape that keeps this one readable. Without a
      // footer the whole dialog collapsed into ONE semantics node: the header's
      // title and the close button's own annotation merged into the enclosing
      // node, so AT-SPI published a single button named "Add a step / Close
      // dialog" with the explanation and every operation nested under it. The
      // title was readable only as part of a control's name, and the control
      // that closes the chooser had no node of its own to activate. The export
      // sheet, the delete confirm and the rename dialog all carry footer
      // actions and all publish the title as text with "Close dialog" beside
      // it; this is the same trap `darkroom_screen.dart` documents for the
      // start offer, at the one host that had no footer.
      actions: [
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Every operation this build registers, whether or not this stack '
            'already carries one. A step arrives switched on and adjustable, '
            'and nothing is written to the master — the recipe replays over '
            'its pixels.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          // No scroll view of its own: the dialog surface already scrolls its
          // body, and a second one nested inside it would size this column
          // against unbounded height.
          for (final op in catalog.ops)
            Padding(
              padding: const EdgeInsets.only(
                bottom: SkotiqTokens.spaceMd,
              ),
              child: _entry(context, colors, op),
            ),
        ],
      ),
    );
  }

  Widget _entry(
    BuildContext context,
    SkotiqColors colors,
    DarkroomOpSpec op,
  ) {
    final title = darkroomOpTitle(op.id);
    final at = state.insertIndexFor(op);
    final refusal = at == null
        ? 'The registry states this operation\'s stage as "${op.stageWire}", '
            'which this build does not model, so this editor cannot say '
            'whether it belongs before or after the stretch.'
        : _channelRefusal(op);
    final placement = at == null ? null : _placement(op, at);
    final measured = _measuredNote(op);
    // Every sentence this card shows, in the order it shows them, on the node
    // that IS the card. The button used to carry the placement rule in its name
    // while the captions beside it published that same sentence again as loose
    // text, so a reader walking nine operations to reach the one they wanted
    // heard every placement rule and every refusal twice. This is the shape
    // `darkroom_screen.dart` already uses for its Back control and its compare
    // ownership strip: one node with the whole sentence, `excludeSemantics` over
    // the children that paint it.
    final name = [
      refusal == null
          ? 'Add $title v${op.version} — ${op.stage.label} stage.'
          : 'Add $title v${op.version} — $refusal',
      if (op.summary.isNotEmpty) op.summary,
      if (refusal == null) placement!,
      if (measured != null) measured,
    ].join(' ');
    void choose() => Navigator.of(context).pop(op);

    return Semantics(
      container: true,
      button: true,
      enabled: refusal == null,
      label: name,
      excludeSemantics: true,
      onTap: refusal == null ? choose : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkotiqButton(
            label: title,
            icon: SkotiqIcons.add,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: refusal == null ? choose : null,
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          // The same two tags the step card carries, so the chooser and the
          // stack name an operation in one vocabulary. A Wrap, because an
          // operation name and a stage label both grow, and this dialog is as
          // narrow as the phone it opens on.
          Wrap(
            spacing: SkotiqTokens.spaceXs,
            runSpacing: SkotiqTokens.spaceXs,
            children: [
              _DarkroomTag(
                label: 'v${op.version}',
                tooltip: 'The operation version a step added now is written '
                    'with. A recipe keeps rendering with its own version.',
              ),
              _DarkroomTag(label: op.stage.label, tooltip: _stageTooltip(op)),
            ],
          ),
          if (op.summary.isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            Text(
              op.summary,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            refusal ?? placement!,
            style: SkotiqTypography.captionSm.copyWith(
              color: refusal == null ? colors.textMuted : colors.warning,
            ),
          ),
          if (measured != null) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            Text(
              measured,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Why the engine would refuse [op] over THIS master's pixels, or null when
  /// it would not — or when the channel count is not known here.
  ///
  /// A precondition the chooser can know from the open master is stated before
  /// the press, never discovered by a failed render: `Color calibrate` was
  /// offered on a one-channel master with its stage rule and its insertion
  /// index spelled out in full and no word about channels, the step committed,
  /// and the next render came back "unsupported channel layout" with the
  /// picture marked stale until the operator found the step and removed it.
  ///
  /// The reason is the engine's own — the `expected` clause of the refusal that
  /// operation raises — joined to the count read off this master's library row,
  /// which is the same fact the Recipe panel's draft note states two inches
  /// away. With no library row there is no count, so nothing is claimed.
  String? _channelRefusal(DarkroomOpSpec op) {
    final needs = kDarkroomThreeChannelOps[op.id];
    if (needs == null) return null;
    final channels = state.masterChannels;
    if (channels == null || channels == 3) return null;
    return 'This master has $channels channel${channels == 1 ? '' : 's'} and '
        'this operation runs over $needs. Adding it would write a step the '
        'engine refuses, and the render would stop there.';
  }

  /// Where the step lands, named by the step it lands in front of.
  String _placement(DarkroomOpSpec op, int at) {
    final steps = state.steps;
    if (steps.isEmpty) return 'Goes in as the first step of the stack.';
    if (at >= steps.length) {
      return 'Goes in at the end of the stack, as step ${steps.length + 1}.';
    }
    final blocking = darkroomOpTitle(steps[at].opId);
    return 'Goes in as step ${at + 1}, ahead of $blocking: a linear-stage '
        'operation cannot run after a stretched one, so this is the last '
        'place in the stack the rule leaves for it.';
  }

  /// What the registry has to measure before this operation can be added, or
  /// null when its parameters all have documented defaults.
  String? _measuredNote(DarkroomOpSpec op) {
    final unmeasured = [
      for (final param in op.params)
        if (param.required && param.defaultValue == null) param.displayName,
    ];
    if (unmeasured.isEmpty) return null;
    final names = unmeasured.length == 1
        ? unmeasured.single
        : '${unmeasured.take(unmeasured.length - 1).join(', ')} and '
            '${unmeasured.last}';
    return 'This build documents no default for $names, so adding it asks the '
        'registry to measure this master first — the same measurement "Draft '
        'for me" makes, and it takes as long.';
  }

  String _stageTooltip(DarkroomOpSpec op) {
    switch (op.stage) {
      case DarkroomOpStage.linear:
        return 'Emits linear pixels, so it has to run before the stretch.';
      case DarkroomOpStage.stretched:
        return 'Emits stretched (display-domain) pixels. Everything after it '
            'works on the stretched image.';
      case DarkroomOpStage.unmodelled:
        return 'The registry names this operation\'s stage as '
            '"${op.stageWire}", which this build does not model.';
    }
  }
}
