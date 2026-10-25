part of '../darkroom_editor.dart';

/// Why "Compare" is unavailable while this master carries one recipe.
///
/// One sentence, used as both the tooltip and the disabled control's
/// accessible name, so the hover and the screen reader say the same thing.
const String _kCompareNeedsSibling =
    'A compare needs a second recipe over these same pixels. Duplicate this '
    'one as a variant to make one.';

/// The strip of branch chips over this master.
const Key kDarkroomBranchStripKey = Key('darkroom-branch-strip');

/// The strip of links to the night's OTHER masters.
const Key kDarkroomSiblingStripKey = Key('darkroom-sibling-strip');

/// The name offered for a new variant of [parentLabel], with a number when the
/// plain one is already worn by a sibling.
///
/// Two branches with one label are two chips nothing on the bar tells apart, two
/// identical rows in the compare picker, and a delete refusal that names the
/// same recipe twice. The suggestion is only a suggestion — the field it lands
/// in is editable and any name, duplicate ones included, can still be typed.
///
/// Compared case-insensitively and on trimmed text, because "Draft variant" and
/// "draft variant " are the same label to the eye reading the bar.
String darkroomVariantNameSuggestion(
  String parentLabel,
  Iterable<String> siblingLabels,
) {
  final taken = {
    for (final label in siblingLabels) label.trim().toLowerCase(),
  };
  final base = '$parentLabel variant';
  var candidate = base;
  var suffix = 1;
  // Each pass names a candidate no earlier pass named, and the labels it has to
  // clear are finite, so the walk ends on the first free name.
  while (taken.contains(candidate.toLowerCase())) {
    suffix++;
    candidate = '$base $suffix';
  }
  return candidate;
}

/// What the delete confirm was answered with.
///
/// Three answers rather than a bool, because a branch with branches of its own
/// has two truthful destructive choices and neither of them is "delete this row
/// and find out": [deleteThisOne] is offered only when it can be carried out.
enum _DarkroomDeleteChoice { keep, deleteThisOne, deleteLine }

/// Who composed a sibling's recipe, in the words its tooltip uses.
///
/// The same three-way distinction the Recipe panel's identity tag makes, so a
/// chip and the panel it leads to cannot disagree about who drafted a stack.
String darkroomSiblingAuthorPhrase(DarkroomSiblingDraft sibling) {
  if (sibling.author == RecipeAuthor.autopilot) {
    return 'drafted by the autopilot';
  }
  return sibling.composedByRegistry
      ? 'drafted at your request'
      : 'written by you';
}

/// The sentence over the sibling strip: how many masters the night produced,
/// and how many of the OTHER ones carry a recipe.
///
/// [drafted] is the count of siblings with a recipe; [siblings] is how many
/// other masters there are. Both numbers are in the sentence, so the verb has
/// to agree with the one it is about — and it did not: the verb was governed by
/// [siblings] while its subject is [drafted], so a night with three masters and
/// one drafted sibling read "1 of the other 2 carry a recipe".
///
/// Pure, and public, so the agreement can be pinned across the counts without
/// standing up a branch bar for each.
String darkroomSiblingSummarySentence({
  required int drafted,
  required int siblings,
}) {
  final total = siblings + 1;
  if (drafted == siblings) {
    return 'This night produced $total masters and every one of them carries '
        'a recipe. The others:';
  }
  // "carries"/"carry" agrees with `drafted`, the count it follows.
  return 'This night produced $total masters; $drafted of the other $siblings '
      '${drafted == 1 ? 'carries' : 'carry'} a recipe:';
}

/// The glyph on a sibling chip.
///
/// A master with NO recipe gets the neutral frame rather than the person: the
/// person icon is what a chip wears to say a human wrote the stack, and a
/// master nobody has interpreted yet would otherwise wear it too.
IconData darkroomSiblingIcon(DarkroomSiblingDraft sibling) {
  if (sibling.recipeId == null) return SkotiqIcons.frame;
  if (sibling.author == RecipeAuthor.autopilot || sibling.composedByRegistry) {
    return SkotiqIcons.sparkle;
  }
  return SkotiqIcons.user;
}

/// The branch switcher: every recipe written over this master, which one is
/// open, and the actions that change the set.
///
/// The bar is deliberately above the panel layout rather than inside a panel:
/// switching branches changes what BOTH the viewport and the history stack
/// describe, so it cannot live inside either of them.
///
/// Three separate statements, never folded into one:
///
///  * who wrote a branch — an autopilot draft is a first interpretation, a user
///    recipe is a decision;
///  * where a branch diverged — the step of its parent it stopped matching;
///  * why a delete was refused — named branches, not a greyed-out button.
class _DarkroomBranchBar extends ConsumerStatefulWidget {
  /// The family this bar draws, and the recipe inside it that is open.
  final DarkroomBranchScope scope;

  /// The key the EDITOR's controller is registered under.
  ///
  /// Deleting the open recipe leaves that controller holding a stack that is no
  /// longer stored, and the bar is the only thing that knows it happened. A
  /// route change cannot be relied on to replace it — see [_promptDelete].
  final DarkroomScope editorScope;

  /// The open recipe's row id.
  final int recipeId;

  /// `integrated_masters.id` the open recipe was framed from, when it carries
  /// one. Deleting the last recipe over a master goes back to it, which is what
  /// offers a fresh start; a recipe with no library row has nowhere to go and
  /// the screen is left to report the empty family instead.
  final int? masterId;

  /// The recipe the compare pane is showing beside the open one, or null when
  /// compare is off.
  final int? compareRecipeId;

  /// How the compare pane draws its two sides.
  final _DarkroomCompareMode compareMode;

  /// Switch the compare pane on against [recipeId], or off when null.
  final void Function(int? recipeId) onCompareWith;

  /// Change how the compare pane draws its two sides.
  final ValueChanged<_DarkroomCompareMode> onCompareModeChanged;

  /// Open the export sheet for the open recipe.
  final VoidCallback onExport;

  /// The other masters the same night produced, with the newest recipe over
  /// each. Empty when the night produced one master.
  final List<DarkroomSiblingDraft> siblings;

  /// Why the night's other masters could not be listed, when they could not.
  final String? siblingsError;

  /// Read a `.skrecipe` sidecar and open it as a new recipe over this master.
  final VoidCallback onImportRecipe;

  /// True while an import is reading a file, so a second press cannot start a
  /// second one.
  final bool importBusy;

  const _DarkroomBranchBar({
    required this.scope,
    required this.editorScope,
    required this.recipeId,
    required this.masterId,
    required this.compareRecipeId,
    required this.compareMode,
    required this.onCompareWith,
    required this.onCompareModeChanged,
    required this.onExport,
    required this.siblings,
    required this.siblingsError,
    required this.onImportRecipe,
    required this.importBusy,
  });

  @override
  ConsumerState<_DarkroomBranchBar> createState() => _DarkroomBranchBarState();
}

class _DarkroomBranchBarState extends ConsumerState<_DarkroomBranchBar> {
  DarkroomBranchController get _branches =>
      ref.read(darkroomBranchControllerProvider(widget.scope).notifier);

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final state = ref.watch(darkroomBranchControllerProvider(widget.scope));

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _chips(colors, state),
          if (state.lineage.length > 1) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            _lineage(colors, state),
          ],
          if (state.lineageError != null) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            SkotiqBanner(
              title: 'The branch history is incomplete',
              tone: BannerTone.warning,
              message: state.lineageError!,
            ),
          ],
          ..._siblings(colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _actions(state),
          if (state.loadError != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            SkotiqBanner(
              title: 'The branches could not be read',
              tone: BannerTone.error,
              message: state.loadError!,
            ),
          ],
          if (state.actionError != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            SkotiqBanner(
              title: 'That branch action did not take effect',
              tone: BannerTone.error,
              message: state.actionError!,
            ),
          ],
          if (state.deleteRefusal != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            _refusal(state.deleteRefusal!),
          ],
        ],
      ),
    );
  }

  /// One chip per recipe over this master.
  ///
  /// Horizontally scrollable rather than wrapped: a long family would otherwise
  /// push the viewport down the screen a row at a time. [_ChipStrip] is what
  /// makes that choice survivable — see its own note.
  Widget _chips(SkotiqColors colors, DarkroomBranchState state) {
    if (state.loading) {
      return Text(
        'Reading the branches written over this master…',
        style: SkotiqTypography.captionSm.copyWith(
          color: colors.textMuted,
        ),
      );
    }
    if (state.branches.isEmpty) {
      return Text(
        'This is the only recipe over this master.',
        style: SkotiqTypography.captionSm.copyWith(
          color: colors.textMuted,
        ),
      );
    }
    return _ChipStrip(
      key: kDarkroomBranchStripKey,
      semanticsLabel: 'Branches over this master',
      children: [
        for (final branch in state.branches) ...[
          _branchChip(colors, branch),
          const SizedBox(width: SkotiqTokens.spaceXs),
        ],
      ],
    );
  }

  Widget _branchChip(SkotiqColors colors, DarkroomBranch branch) {
    final current = branch.id == widget.recipeId;
    final comparing = branch.id == widget.compareRecipeId;
    final author = branch.author == RecipeAuthor.autopilot
        ? 'drafted by the autopilot'
        : 'written by you';
    final steps = branch.stepCount == null
        ? 'its stored step list could not be read'
        : '${branch.stepCount} step${branch.stepCount == 1 ? '' : 's'}';
    final diverged = branch.divergenceIndex == null
        ? 'a root recipe'
        : 'diverges from recipe ${branch.parentRecipeId} after step '
            '${branch.divergenceIndex}';
    final label = comparing ? '${branch.label} (B)' : branch.label;
    final chip = SkotiqChip(
      label: label,
      icon: branch.author == RecipeAuthor.autopilot
          ? SkotiqIcons.sparkle
          : SkotiqIcons.user,
      selected: current,
      onTap:
          current ? null : () => context.go(darkroomRecipeLocation(branch.id)),
    );
    return Tooltip(
      message: '${branch.label} — $author, $steps, $diverged.'
          '${comparing ? ' Shown as B in the compare pane.' : ''}',
      // A tappable chip publishes its OWN node, carrying the label, the button
      // role, the enabled flag and the selected state. Wrapping that in a
      // second annotation is what put a nameless node with no enabled state
      // above every branch button — assistive tech read a disabled, unnamed
      // button wrapping the real one. The open recipe's chip has no tap and so
      // publishes no node of its own; it gets one node here that says what it
      // is rather than offering an action it cannot perform.
      child: current
          ? Semantics(
              container: true,
              selected: true,
              label: '$label — the recipe this editor is showing',
              excludeSemantics: true,
              child: chip,
            )
          : chip,
    );
  }

  /// The night's OTHER masters, and the recipe over each.
  ///
  /// Every in-app "refine this night" control resolves one master for the
  /// session and opens it, so a four-filter night hands the editor one of four
  /// drafts. The branch chips above describe the branches of THIS master only,
  /// and nothing else on the screen said the other three drafts existed — they
  /// were reachable, but only by leaving for the session review and walking
  /// into the workbench.
  ///
  /// Master-scoped links, not recipe-scoped: a master with no recipe opens the
  /// offer to compose one, and a master with several opens its newest, which is
  /// the same thing every other entry point does.
  List<Widget> _siblings(SkotiqColors colors) {
    final error = widget.siblingsError;
    if (error != null) {
      return [
        const SizedBox(height: SkotiqTokens.spaceXs),
        SkotiqBanner(
          title: 'The night\'s other masters could not be listed',
          tone: BannerTone.info,
          message: error,
        ),
      ];
    }
    final siblings = widget.siblings;
    if (siblings.isEmpty) return const [];
    final drafted = siblings.where((s) => s.recipeId != null).length;
    return [
      const SizedBox(height: SkotiqTokens.spaceXs),
      Text(
        darkroomSiblingSummarySentence(
          drafted: drafted,
          siblings: siblings.length,
        ),
        style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
      ),
      const SizedBox(height: SkotiqTokens.spaceXs),
      _ChipStrip(
        key: kDarkroomSiblingStripKey,
        semanticsLabel: 'The night\'s other masters',
        children: [
          for (final sibling in siblings) ...[
            Tooltip(
              message: sibling.recipeId == null
                  ? '${sibling.masterName} has no recipe yet. Opening it '
                      'offers a draft or an empty stack.'
                  : '${sibling.masterName} — '
                      '"${sibling.recipeName ?? 'Recipe '
                          '${sibling.recipeId}'}", '
                      '${darkroomSiblingAuthorPhrase(sibling)}.',
              child: SkotiqChip(
                label: sibling.recipeId == null
                    ? '${sibling.label} — no recipe yet'
                    : sibling.label,
                icon: darkroomSiblingIcon(sibling),
                onTap: () =>
                    context.go(darkroomMasterLocation(sibling.masterId)),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
          ],
        ],
      ),
    ];
  }

  /// The open recipe's ancestry, so a branch says where it came from.
  Widget _lineage(SkotiqColors colors, DarkroomBranchState state) {
    final parts = <String>[];
    for (final entry in state.lineage) {
      parts.add(
        entry.divergenceIndex == null
            ? entry.label
            : '${entry.label} (from step ${entry.divergenceIndex})',
      );
    }
    return Text(
      'Lineage: ${parts.join(' → ')}',
      style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
    );
  }

  Widget _actions(DarkroomBranchState state) {
    final compareTargets = state.branches
        .where((branch) => branch.id != widget.recipeId)
        .toList(growable: false);
    final comparing = widget.compareRecipeId != null;

    return Wrap(
      spacing: SkotiqTokens.spaceXs,
      runSpacing: SkotiqTokens.spaceXs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SkotiqButton(
          label: 'Duplicate as variant',
          icon: SkotiqIcons.copy,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: state.busy ? null : _promptDuplicate,
        ),
        SkotiqButton(
          label: 'Rename',
          icon: SkotiqIcons.edit,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: state.busy ? null : _promptRename,
        ),
        SkotiqButton(
          label: 'Delete branch',
          icon: SkotiqIcons.delete,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: state.busy ? null : _promptDelete,
        ),
        if (comparing)
          SkotiqButton(
            label: 'Stop comparing',
            icon: SkotiqIcons.close,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => widget.onCompareWith(null),
          )
        else if (compareTargets.isEmpty)
          // Disabled AND explained. The button's own semantics node published
          // an enabled push button while the paint said otherwise, so the only
          // statement of "there is nothing to compare against" was a hover
          // tooltip — invisible to the keyboard, to a screen reader, and to
          // anyone who simply pressed it. The reason rides on the accessible
          // name and the node is excluded below so one honest node is published
          // rather than two contradicting ones.
          Tooltip(
            message: _kCompareNeedsSibling,
            child: Semantics(
              // Its own node, not an annotation merged into whatever encloses
              // it: merged, the disabled flag lands on a container that is not
              // this control and the button still publishes as live.
              container: true,
              button: true,
              enabled: false,
              label: 'Compare — $_kCompareNeedsSibling',
              child: const ExcludeSemantics(
                child: SkotiqButton(
                  label: 'Compare',
                  icon: SkotiqIcons.layers,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: null,
                ),
              ),
            ),
          )
        else
          SkotiqButton(
            label: 'Compare with…',
            icon: SkotiqIcons.layers,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => _promptCompare(compareTargets),
          ),
        if (comparing) ...[
          SkotiqChip(
            label: 'Side by side',
            selected: widget.compareMode == _DarkroomCompareMode.sideBySide,
            onTap: () => widget.onCompareModeChanged(
              _DarkroomCompareMode.sideBySide,
            ),
          ),
          SkotiqChip(
            label: 'Blink',
            selected: widget.compareMode == _DarkroomCompareMode.blink,
            onTap: () =>
                widget.onCompareModeChanged(_DarkroomCompareMode.blink),
          ),
        ],
        SkotiqButton(
          label: 'Export…',
          icon: SkotiqIcons.download,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: widget.onExport,
        ),
        // The other half of the sidecar the export sheet promises writes "so
        // the recipe survives outside the database". Without a reader that
        // sentence described a file the product could not consume.
        SkotiqButton(
          label: 'Import .skrecipe',
          icon: SkotiqIcons.upload,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          isLoading: widget.importBusy,
          onPressed: widget.importBusy ? null : widget.onImportRecipe,
        ),
      ],
    );
  }

  Widget _refusal(DarkroomBranchDeleteRefusal refusal) {
    return SkotiqBanner(
      tone: BannerTone.warning,
      title: 'That branch has branches of its own',
      message: refusal.explanation,
      action: Wrap(
        spacing: SkotiqTokens.spaceXs,
        runSpacing: SkotiqTokens.spaceXs,
        children: [
          SkotiqButton(
            label: 'Delete "${refusal.label}" and its '
                '${refusal.childIds.length} '
                '${refusal.childIds.length == 1 ? 'branch' : 'branches'}',
            icon: SkotiqIcons.delete,
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
            onPressed: () => _deleteLine(refusal.recipeId),
          ),
          SkotiqButton(
            label: 'Keep them',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: _branches.dismissRefusal,
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Actions
  // -----------------------------------------------------------------------

  Future<void> _promptDuplicate() async {
    final state = ref.read(darkroomBranchControllerProvider(widget.scope));
    final current = state.branchFor(widget.recipeId);
    final suggested = darkroomVariantNameSuggestion(
      current?.label ?? 'Recipe ${widget.recipeId}',
      [for (final branch in state.branches) branch.label],
    );
    final name = await _promptForName(
      title: 'Duplicate as variant',
      body:
          'A variant is a second recipe over the same linear master. It starts '
          'as a copy of this stack and records that it branched from it, so '
          'editing the variant never touches this one.',
      initial: suggested,
      confirmLabel: 'Create variant',
    );
    if (name == null) return;
    final id = await _branches.duplicateAsVariant(
      sourceRecipeId: widget.recipeId,
      name: name,
    );
    if (id == null || !mounted) return;
    _branches.acknowledgeCreatedBranch();
    if (!context.mounted) return;
    context.go(darkroomRecipeLocation(id));
  }

  Future<void> _promptRename() async {
    final state = ref.read(darkroomBranchControllerProvider(widget.scope));
    final current = state.branchFor(widget.recipeId);
    if (current == null) {
      // A blank rename field would propose erasing a name that has not been
      // loaded; refuse until the branch list is read.
      SkotiqToastHelper.show(
        context: context,
        message:
            'The branches over this master have not been read yet, so this '
            'recipe\'s current name is unknown. Reload and try again.',
        severity: SkotiqAlertSeverity.warning,
      );
      return;
    }
    final name = await _promptForName(
      title: 'Rename this branch',
      body:
          'The name is the label on the branch bar. It says nothing about the '
          'stack, so renaming changes no step and re-renders nothing.',
      initial: current.label,
      confirmLabel: 'Rename',
    );
    if (name == null) return;
    await _branches.renameBranch(widget.recipeId, name);
  }

  Future<void> _promptDelete() async {
    final state = ref.read(darkroomBranchControllerProvider(widget.scope));
    final current = state.branchFor(widget.recipeId);
    final label = current?.label ?? 'Recipe ${widget.recipeId}';
    // The children are known BEFORE the dialog is built, and the dialog said
    // nothing about them: the operator confirmed a destructive action and only
    // then met the refusal naming branches they had not been told existed.
    final childIds = current?.childIds ?? const <int>[];
    final childLabels = [
      for (final id in childIds) state.branchFor(id)?.label ?? 'Recipe $id',
    ];
    final hasChildren = childLabels.isNotEmpty;
    final lineLabel = 'Delete "$label" and its ${childLabels.length} '
        '${childLabels.length == 1 ? 'branch' : 'branches'}';
    // A branch with branches of its own cannot be deleted on its own, and this
    // dialog knows it — it is quoting the very children the engine will refuse
    // over. Offering "Delete" here made the operator perform a step whose only
    // possible outcome was a refusal, and only THEN offered the whole line. So
    // the choice that can actually be carried out is the one on the button,
    // named in full, and the other one plainly says the branches stay.
    // Dismissible, like every other modal in this app: Escape and a tap on the
    // barrier answer NULL, which falls through both branches below and leaves
    // the family exactly as it was — the outcome "Keep it" has. Only the
    // destructive button deletes anything, so the way out an operator reaches
    // for first cannot cost them a branch. A barrier closed here answers
    // neither the key nor the tap, while the shared [ConfirmDialog] and the
    // export sheet on this same screen both answer them.
    final choice = await showDialog<_DarkroomDeleteChoice>(
      context: context,
      builder: (dialogContext) => SkotiqDialog(
        title: 'Delete "$label"?',
        icon: SkotiqIcons.delete,
        width: 480,
        actions: [
          SkotiqButton(
            label: 'Keep it',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => Navigator.of(dialogContext).pop(
              _DarkroomDeleteChoice.keep,
            ),
          ),
          SkotiqButton(
            label: hasChildren ? lineLabel : 'Delete',
            icon: SkotiqIcons.delete,
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
            onPressed: () => Navigator.of(dialogContext).pop(
              hasChildren
                  ? _DarkroomDeleteChoice.deleteLine
                  : _DarkroomDeleteChoice.deleteThisOne,
            ),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasChildren) ...[
              SkotiqBanner(
                tone: BannerTone.warning,
                title: childLabels.length == 1
                    ? 'One branch diverges from this one'
                    : '${childLabels.length} branches diverge from this one',
                // Agrees in number with the branches it names: one child reads
                // "records the step … it stopped matching", several read
                // "record … they stopped matching".
                message: '${childLabels.join(', ')} '
                    '${childLabels.length == 1 ? 'records' : 'record'} the '
                    'step of "$label" '
                    '${childLabels.length == 1 ? 'it' : 'they'} stopped '
                    'matching, and re-pointing '
                    '${childLabels.length == 1 ? 'it' : 'them'} at this '
                    'branch\'s own parent would leave '
                    '${childLabels.length == 1 ? 'it' : 'them'} rendering a '
                    'lineage that never happened. So "$label" goes only with '
                    '${childLabels.length == 1 ? 'it' : 'them'}: '
                    '${childLabels.length + 1} recipes in all, or none.',
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
            ],
            Text(
              'The recipe row goes; the linear master it renders does not. '
              'Nothing in the Darkroom has ever written to those pixels, so '
              'deleting this branch loses only the interpretation.',
              style: SkotiqTypography.bodySm.copyWith(
                color: SkotiqColors.of(dialogContext).textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
    if (choice == _DarkroomDeleteChoice.deleteLine) {
      await _deleteLine(widget.recipeId);
      return;
    }
    if (choice != _DarkroomDeleteChoice.deleteThisOne) return;

    final before = ref.read(darkroomBranchControllerProvider(widget.scope));
    final parentId = before.branchFor(widget.recipeId)?.parentRecipeId;
    final deleted = await _branches.deleteBranch(widget.recipeId);
    if (!deleted || !mounted || !context.mounted) return;

    // The row is gone, so the editor's controller is holding a recipe that no
    // longer exists. It is retired HERE rather than left to the navigation
    // below, because the fallback can be the location the screen is already on:
    // every in-app entry point opens the Darkroom as `/darkroom?master=<id>`,
    // and going to a location that is already current changes no route, so the
    // same scope hands back the same notifier and the deleted recipe stays on
    // screen with every action still live. Invalidating the family member is
    // what makes the screen re-read the master and offer a fresh start; when
    // the fallback IS a different location, this retires a controller that
    // autoDispose was about to drop anyway.
    ref.invalidate(darkroomControllerProvider(widget.editorScope));

    // Where the screen goes next: the branch this one came from, or the master,
    // which offers a fresh start.
    final after = ref.read(darkroomBranchControllerProvider(widget.scope));
    final fallback = parentId ?? _firstBranchId(after);
    if (fallback != null) {
      context.go(darkroomRecipeLocation(fallback));
      return;
    }
    final masterId = widget.masterId;
    if (masterId != null) context.go(darkroomMasterLocation(masterId));
  }

  /// The id of the first recipe still in the family, or null when none is left.
  static int? _firstBranchId(DarkroomBranchState state) =>
      state.branches.isEmpty ? null : state.branches.first.id;

  /// Delete [recipeId] and everything descended from it.
  ///
  /// Reached two ways, and they are the same act: chosen up front in the
  /// confirm, which already knows the branch has branches, or from the engine's
  /// refusal when the family changed under a delete that was legal when it was
  /// asked for.
  Future<void> _deleteLine(int recipeId) async {
    final deleted = await _branches.deleteBranchLine(recipeId);
    if (deleted == null || !mounted || !context.mounted) return;
    // The line can include the open recipe, and there may be no branch left to
    // go to at all — so the editor's controller is retired for the same reason
    // it is in [_promptDelete].
    ref.invalidate(darkroomControllerProvider(widget.editorScope));
    SkotiqToastHelper.show(
      context: context,
      message: '$deleted recipe${deleted == 1 ? '' : 's'} deleted. The linear '
          'master is untouched.',
      severity: SkotiqAlertSeverity.success,
    );
    final after = ref.read(darkroomBranchControllerProvider(widget.scope));
    final fallback = _firstBranchId(after);
    if (fallback != null && context.mounted) {
      context.go(darkroomRecipeLocation(fallback));
      return;
    }
    // The same tail [_promptDelete] has, and its absence here is what stranded
    // the editor: a cascade delete that took the last recipe over a master left
    // the route scoped to the dead recipe id, so the screen rendered "Recipe 1
    // does not exist" over a master that was intact on disk and one link away
    // from offering a fresh start.
    final masterId = widget.masterId;
    if (masterId != null && context.mounted) {
      context.go(darkroomMasterLocation(masterId));
    }
  }

  Future<void> _promptCompare(List<DarkroomBranch> targets) async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        final colors = SkotiqColors.of(dialogContext);
        return SkotiqDialog(
          title: 'Compare with',
          icon: SkotiqIcons.layers,
          width: 480,
          // A footer action, for the reason the add-step chooser's own comment
          // records: a [SkotiqDialog] with none collapses its header into
          // the enclosing semantics node, and this picker reached AT-SPI as one
          // button named "Compare with / Close dialog" with the explanation and
          // the branch buttons nested inside it. Backing out of a chooser also
          // deserves a control of its own rather than only the header's X.
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Both sides render the same linear master, so what differs on '
                'screen is the interpretation and nothing else. Zoom and pan '
                'stay locked together.',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              for (final branch in targets)
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: SkotiqTokens.spaceSm,
                  ),
                  child: _compareOption(
                    colors,
                    branch,
                    () => Navigator.of(dialogContext).pop(branch.id),
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (chosen == null) return;
    widget.onCompareWith(chosen);
  }

  /// One branch to compare against, as a row that LOOKS like a choice.
  ///
  /// The picker used to list its options as centred label text inside a hairline
  /// outline, in a dialog whose only element painted as a control was Cancel:
  /// the accessible names were right and the eye had nothing to aim at, so the
  /// obvious click — the middle of the row — did nothing unless it landed on the
  /// text itself. This is the card the step cards and the rest of the app's rows
  /// already use: a surface that lifts on hover, the author's glyph, the name
  /// left-aligned, and a chevron saying the row leads somewhere. The whole card
  /// takes the tap.
  Widget _compareOption(
    SkotiqColors colors,
    DarkroomBranch branch,
    VoidCallback choose,
  ) {
    final autopilot = branch.author == RecipeAuthor.autopilot;
    return Semantics(
      container: true,
      button: true,
      // Every option in this picker is choosable — the picker lists only the
      // branches compare CAN run against — and a node that names no enabled
      // state resolves none, which the AT-SPI bridge publishes as no ENABLED
      // state at all. Without this field the one route into A/B compare was
      // announced to a screen reader as unavailable while a click on the same
      // row armed the comparison. `_add_step.dart` and the Back control both
      // carry the field for the same reason.
      enabled: true,
      label: autopilot ? '${branch.label} — the autopilot draft' : branch.label,
      excludeSemantics: true,
      onTap: choose,
      child: SkotiqCard(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceMd,
          vertical: SkotiqTokens.spaceSm,
        ),
        onTap: choose,
        enableHover: true,
        child: Row(
          children: [
            Icon(
              autopilot ? SkotiqIcons.sparkle : SkotiqIcons.user,
              size: SkotiqTokens.iconSm,
              color: colors.textSecondary,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    branch.label,
                    style: SkotiqTypography.labelStrong.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  if (autopilot) ...[
                    const SizedBox(height: SkotiqTokens.spaceXs),
                    Text(
                      'the autopilot draft',
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Icon(
              SkotiqIcons.chevronRight,
              size: SkotiqTokens.iconSm,
              color: colors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  /// A one-field dialog for a branch name.
  ///
  /// Answers null when the operator backed out, and the trimmed text otherwise;
  /// an empty field cannot be confirmed, so a branch never loses its label to a
  /// stray return key.
  ///
  /// Dismissible: Escape and a tap on the barrier answer null, which is exactly
  /// what Cancel answers, and every caller reads null as "renamed nothing,
  /// created nothing". The field's text is dropped with the dialog — the same
  /// thing Cancel does with it — and nothing typed here has reached the recipe.
  Future<String?> _promptForName({
    required String title,
    required String body,
    required String initial,
    required String confirmLabel,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _DarkroomNameDialog(
        title: title,
        body: body,
        initial: initial,
        confirmLabel: confirmLabel,
      ),
    );
  }
}

/// The name field behind "duplicate as variant" and "rename".
///
/// A widget with its own state rather than a `StatefulBuilder` over a captured
/// controller: the dialog route keeps rebuilding through its exit transition,
/// and a controller disposed when the future completed would be read after
/// disposal on the way out.
class _DarkroomNameDialog extends StatefulWidget {
  final String title;
  final String body;
  final String initial;
  final String confirmLabel;

  const _DarkroomNameDialog({
    required this.title,
    required this.body,
    required this.initial,
    required this.confirmLabel,
  });

  @override
  State<_DarkroomNameDialog> createState() => _DarkroomNameDialogState();
}

class _DarkroomNameDialogState extends State<_DarkroomNameDialog> {
  /// The suggestion arrives SELECTED, because the field arrives focused.
  ///
  /// A controller built from `text:` alone leaves the caret collapsed at the
  /// end of that text. With `autofocus: true` the first keystroke therefore
  /// landed AFTER the suggestion instead of replacing it: measured against the
  /// release bundle, "Duplicate as variant" proposed "Master · B draft
  /// variant", the operator typed "Harder stretch" without touching the field,
  /// and the branch was created — in the recipes table and on the branch bar —
  /// as "Master · B draft variantHarder stretch".
  ///
  /// A name this dialog proposed is a proposal, and a selected proposal is how
  /// the platform states that: typing replaces it, and one arrow key or a click
  /// keeps it. The GTK save dialog one screen along in this same flow opens the
  /// same way, on the same suggestion.
  late final TextEditingController _controller =
      TextEditingController.fromValue(
    TextEditingValue(
      text: widget.initial,
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: widget.initial.length,
      ),
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final text = _controller.text.trim();
    return SkotiqDialog(
      title: widget.title,
      icon: SkotiqIcons.edit,
      width: 480,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: widget.confirmLabel,
          size: ButtonSize.small,
          onPressed: text.isEmpty ? null : _confirm,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.body,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqTextField(
            controller: _controller,
            label: 'Branch name',
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _confirm(),
            errorText: text.isEmpty
                ? 'A branch needs a name to be told apart from the others on '
                    'the bar.'
                : null,
          ),
        ],
      ),
    );
  }
}

/// A horizontal row of chips that stays REACHABLE when it runs off the edge.
///
/// Both chip rows on this bar — the branches over this master and the links to
/// the night's other masters — are horizontal scrollers rather than `Wrap`s, on
/// purpose: a night with eight masters would otherwise push the image down the
/// screen a row at a time, and this bar sits above the viewport. That choice is
/// only defensible if the chips behind the edge can actually be got at, and in
/// the plain form it shipped as, they could not. Measured at 430x900 with five
/// branches: the last chip laid out at x=494 in a 430-wide window, no scrollbar
/// was drawn, a mouse wheel over the row moved it 0px (Flutter sends wheel
/// deltas along the scrollable's own axis, and a mouse produces vertical ones),
/// and a click-drag was refused outright because `ScrollBehavior.dragDevices`
/// excludes the mouse on every platform. The chips were in the semantics tree
/// and out of reach of the pointer — announced but unusable.
///
/// So one shape, used by both rows, with three ways in:
///
///  * a scrollbar, always visible while there IS an overflow, which is the only
///    thing on screen that says more chips exist and is itself draggable;
///  * a vertical wheel translated onto the horizontal axis, which is what a
///    desktop hand reaches for first — the same translation
///    [AdaptiveTabBar] does for the same reason;
///  * drag with any pointer, mouse included, the way a finger already worked.
///
/// Not a `Wrap` — the offer view uses one for its own copy of this list, and it
/// can afford to: it is a full-width empty state with no viewport under it to
/// push down.
class _ChipStrip extends StatefulWidget {
  const _ChipStrip({
    super.key,
    required this.children,
    required this.semanticsLabel,
  });

  final List<Widget> children;

  /// Names the scrollable region for assistive tech, which otherwise announces
  /// an unnamed scroll area between the chips and their heading.
  final String semanticsLabel;

  @override
  State<_ChipStrip> createState() => _ChipStripState();
}

class _ChipStripState extends State<_ChipStrip> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Turn a vertical wheel into horizontal movement.
  ///
  /// Horizontal deltas are left alone: the [Scrollable] already consumes those,
  /// and handling them here would scroll twice per notch.
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dx != 0 || event.scrollDelta.dy == 0) return;
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.maxScrollExtent <= 0) return;
    final target = (position.pixels + event.scrollDelta.dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    _controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: widget.semanticsLabel,
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: const {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
              PointerDeviceKind.invertedStylus,
              PointerDeviceKind.unknown,
            },
            // The strip draws its own scrollbar below; the behaviour's would be
            // a second one over the same viewport.
            scrollbars: false,
          ),
          child: Scrollbar(
            controller: _controller,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              // Room under the chips for the thumb, which is painted inside the
              // viewport and would otherwise sit across their bottom edge. The
              // gap is reserved whether or not a thumb appears — Flutter paints
              // one only when there is something to scroll, and a bar that grew
              // 8px the moment a branch was added would shove the viewport down
              // for a reason nobody could see.
              padding: const EdgeInsets.only(
                bottom: SkotiqTokens.spaceSm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: widget.children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
