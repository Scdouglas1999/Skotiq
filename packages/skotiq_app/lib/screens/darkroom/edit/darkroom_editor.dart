/// The Darkroom editor: a registered image on the left, the recipe that
/// interprets it on the right.
///
/// The editor is one rendering of one [DarkroomController] state. Nothing here
/// touches pixels or the recipe engine directly — the controller owns the
/// render loop and every native call goes through `DarkroomSeam`, so this file
/// only decides what the operator sees and which controller method a gesture
/// calls.
///
/// It is the body of the Darkroom's Edit tab, scoped by `recipe=<id>` (a recipe
/// by row id) or `master=<id>` (a registered image, whose newest recipe opens —
/// or, when it has none, an offer to create one).
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Directory;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show OrdinalSortKey;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import '../../../utils/exported_file_reveal.dart';
import '../../../widgets/red_night_filter.dart';
import '../../stack_result/stack_and_share_dialog.dart'
    show describeStackShareFailure;
import '../darkroom_branch_controller.dart';
import '../darkroom_controller.dart';
import '../darkroom_measured_values.dart';
import 'darkroom_image_library.dart';

part 'editor_parts/_image_surface.dart';
part 'editor_parts/_viewport.dart';
part 'editor_parts/_history_panel.dart';
part 'editor_parts/_add_step.dart';
part 'editor_parts/_recipe_panel.dart';
part 'editor_parts/_branch_bar.dart';
part 'editor_parts/_compare.dart';
part 'editor_parts/_export_sheet.dart';
part 'editor_parts/_histogram.dart';

/// The recipe editor over one registered image.
class DarkroomEditor extends ConsumerStatefulWidget {
  /// What the route asked to open. Never empty: the Edit tab shows its image
  /// list instead of an editor when nothing is named.
  final DarkroomScope scope;

  /// Whether the branch bar lists the other images of the night. False when
  /// the Edit tab's image list is on screen beside the editor.
  final bool showSiblings;

  const DarkroomEditor({
    super.key,
    required this.scope,
    this.showSiblings = true,
  });

  @override
  ConsumerState<DarkroomEditor> createState() => _DarkroomEditorState();
}

class _DarkroomEditorState extends ConsumerState<DarkroomEditor> {
  /// The attempt number of the refusal this editor has already announced, so a
  /// rebuild does not toast the same occurrence twice. Zero when there is none.
  ///
  /// The attempt, not the sentence: two refusals of the same move for the same
  /// reason are byte-identical, and deduping on the string swallowed the second
  /// one. The controller stamps each refusal with the attempt that raised it.
  int _lastShownRefusal = 0;
  int _lastShownInsertRefusal = 0;
  String? _lastShownSaveError;

  /// The recipe the compare pane draws beside the open one, or null when the
  /// editor is showing one recipe.
  int? _compareRecipeId;

  _DarkroomCompareMode _compareMode = _DarkroomCompareMode.sideBySide;

  DarkroomController get _controller =>
      ref.read(darkroomControllerProvider(widget.scope).notifier);

  @override
  void didUpdateWidget(covariant DarkroomEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scope != oldWidget.scope) {
      // Switching branches replaces the A side, and the B side was chosen
      // against the recipe that is no longer open.
      _compareRecipeId = null;
      _lastShownRefusal = 0;
      _lastShownInsertRefusal = 0;
      _lastShownSaveError = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final state = ref.watch(darkroomControllerProvider(widget.scope));
    // A recipe created, imported or deleted here changes the image list's
    // recipe counts, so the list is read again whenever the open recipe does.
    ref.listen(
      darkroomControllerProvider(widget.scope).select((s) => s.recipeId),
      (previous, next) {
        if (previous != next) ref.invalidate(darkroomImageLibraryProvider);
      },
    );

    // A refused reorder and a failed write are both things the operator did
    // that did not take effect, so each is announced once per OCCURRENCE — the
    // attempt the controller stamped on it, not the words it carries.
    if (state.reorderRefusal == null) {
      _lastShownRefusal = 0;
    } else if (state.reorderRefusalAttempt != _lastShownRefusal) {
      _lastShownRefusal = state.reorderRefusalAttempt;
      _toast(state.reorderRefusal!, SkotiqAlertSeverity.warning);
    }
    // Announced as well as printed: the chooser closes on the choice, so a
    // refused insert leaves a stack that looks untouched.
    if (state.insertRefusal == null) {
      _lastShownInsertRefusal = 0;
    } else if (state.insertRefusalAttempt != _lastShownInsertRefusal) {
      _lastShownInsertRefusal = state.insertRefusalAttempt;
      _toast(state.insertRefusal!, SkotiqAlertSeverity.warning);
    }
    if (state.saveError == null) {
      _lastShownSaveError = null;
    } else if (state.saveError != _lastShownSaveError) {
      _lastShownSaveError = state.saveError;
      _toast(state.saveError!, SkotiqAlertSeverity.error);
    }

    final image = _openImage(state);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _leave,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _leave,
      },
      child: Focus(
        autofocus: true,
        // Publishing this node annotates the whole editor as a focusable
        // control with no enabled state, which the AT-SPI bridge reports as a
        // disabled button wrapping the editor.
        includeSemantics: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DarkroomEditorBar(
              image: image,
              recipeName: state.hasRecipe ? state.recipeName : null,
              offerName: state.offer?.masterName,
              back: _backControl(
                savePending: state.savePending,
                target: image?.target,
              ),
              action: _headerAction(state),
            ),
            Expanded(child: _body(context, colors, state)),
          ],
        ),
      ),
    );
  }

  /// The registered image this editor is on, from the Edit tab's library, or
  /// null while the library is loading or when the image is not in it.
  DarkroomLibraryImage? _openImage(DarkroomState state) {
    final masterId = state.masterId ?? widget.scope.masterId;
    if (masterId == null) return null;
    final library = ref.watch(darkroomImageLibraryProvider).valueOrNull;
    if (library == null) return null;
    for (final target in library) {
      for (final image in target.images) {
        if (image.master.id == masterId) return image;
      }
    }
    return null;
  }

  void _leave() {
    final state = ref.read(darkroomControllerProvider(widget.scope));
    leaveDarkroomEdit(context, target: _openImage(state)?.target);
  }

  /// The way out, at the left of the editor bar.
  ///
  /// [savePending] is stated on the control itself, because it decides what
  /// leaving does: the pending write is issued by the controller's dispose.
  Widget _backControl({required bool savePending, required String? target}) {
    final where = darkroomEditBackDestination(context, target: target);
    final label = savePending
        ? '$where — this edit is still being written to the recipe, and '
            'leaving issues that write'
        : where;
    return Semantics(
      container: true,
      button: true,
      enabled: true,
      label: label,
      excludeSemantics: true,
      onTap: _leave,
      child: Tooltip(
        message: '$label. Escape and Alt+Left do the same.',
        child: SkotiqButton(
          key: const ValueKey('darkroom_editor_back'),
          label: 'Back',
          icon: SkotiqIcons.arrowLeft,
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: _leave,
        ),
      ),
    );
  }

  void _toast(String message, SkotiqAlertSeverity severity) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SkotiqToastHelper.show(
        context: context,
        message: message,
        severity: severity,
      );
    });
  }

  /// The header's single action slot.
  ///
  /// While a render is in the engine it becomes the stop, following the flat
  /// wizard: the stop is cooperative, so the button says "Stopping…" until the
  /// render answers rather than pretending the request was instant.
  Widget? _headerAction(DarkroomState state) {
    if (!state.hasRecipe && state.offer == null) return null;
    if (state.rendering) {
      return SkotiqButton(
        label: state.cancelRequested ? 'Stopping…' : 'Stop render',
        icon: SkotiqIcons.stop,
        variant: ButtonVariant.destructive,
        size: ButtonSize.small,
        onPressed: state.cancelRequested ? null : _controller.cancelRender,
      );
    }
    return SkotiqButton(
      label: 'Reload',
      icon: SkotiqIcons.refresh,
      variant: ButtonVariant.secondary,
      size: ButtonSize.small,
      onPressed: _controller.refresh,
    );
  }

  Widget _body(
    BuildContext context,
    SkotiqColors colors,
    DarkroomState state,
  ) {
    if (state.loading) {
      return const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
    }
    final loadError = state.loadError;
    if (loadError != null) {
      // The header's own action is suppressed here — there is no recipe to
      // reload — so this empty state is the whole screen. Without a way out of
      // it the only route back is the nav rail, and the reason it names (a
      // recipe or master that is gone) is one the session review can answer:
      // it lists the masters that DO have pixels to interpret.
      return EmptyState(
        icon: SkotiqIcons.imageOff,
        title: 'Nothing to open in the Darkroom',
        body: loadError,
        action: _DarkroomFailureExit(scope: widget.scope),
      );
    }
    final offer = state.offer;
    if (offer != null) {
      return _DarkroomStartOfferView(
        offer: offer,
        busy: state.offerBusy,
        error: state.offerError,
        // Beside the Edit tab's image list the night's other images are on
        // screen already, so the offer does not list them again.
        siblings: widget.showSiblings ? state.siblings : const [],
        siblingsError: widget.showSiblings ? state.siblingsError : null,
        onStartFromLinear: _controller.startFromLinear,
        onDraftForMe: _controller.draftForMe,
        onImportRecipe: () => unawaited(_controller.importRecipe()),
        onDismissError: _controller.dismissOfferError,
      );
    }

    // The branch bar sits above the panels because switching branches changes
    // what BOTH the viewport and the history stack describe.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DarkroomBranchBar(
          scope: DarkroomBranchScope(
            masterPath: state.baseMasterPath,
            recipeId: state.recipeId,
          ),
          editorScope: widget.scope,
          recipeId: state.recipeId!,
          masterId: state.masterId,
          compareRecipeId: _compareRecipeId,
          compareMode: _compareMode,
          onCompareWith: (id) => setState(() => _compareRecipeId = id),
          onCompareModeChanged: (mode) => setState(() => _compareMode = mode),
          onExport: () => _openExportSheet(state),
          siblings: state.siblings,
          siblingsError: state.siblingsError,
          onImportRecipe: () => unawaited(_controller.importRecipe()),
          importBusy: state.offerBusy,
          showSiblings: widget.showSiblings,
        ),
        // The branch bar's `Import .skrecipe` writes its refusals into
        // `offerError`, the same field the start offer's copy of that control
        // uses — and this layout has no offer, so until this alert existed
        // every refusal on this path (a file that is not JSON, a sidecar with
        // no steps, an unreadable path) was composed and then thrown away. A
        // chooser that closed and did nothing is indistinguishable from a
        // broken button, and the operator's recipe count silently did not move.
        if (state.offerError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SkotiqTokens.spaceMd,
              0,
              SkotiqTokens.spaceMd,
              SkotiqTokens.spaceSm,
            ),
            child: SkotiqBanner(
              title: 'That recipe file was not imported',
              key: const ValueKey('darkroom_import_refusal'),
              tone: BannerTone.error,
              message: state.offerError!,
              onDismiss: _controller.dismissOfferError,
            ),
          ),
        Expanded(child: _editorOrCompare(context, colors, state)),
      ],
    );
  }

  /// The editor, or the two-recipe compare when one is armed.
  ///
  /// Compare replaces the PRIMARY region and nothing else. It used to replace
  /// the whole panel layout, which took the Recipe and History panels off the
  /// screen and out of the accessibility tree — so the one thing an A/B compare
  /// is for, reading what differs between two interpretations, was reduced to
  /// two pictures with no way to see which steps differ, beside a picker whose
  /// own copy promises "what differs on screen is the interpretation". The
  /// panels are collapsible on every layout this screen takes, so keeping them
  /// costs the comparator nothing: a phone still segments, and a desktop panel
  /// still drags down to 280 pixels or across to give the two panes the width.
  Widget _editorOrCompare(
    BuildContext context,
    SkotiqColors colors,
    DarkroomState state,
  ) {
    final compareId = _compareRecipeId;
    final aLabel = state.recipeName.isEmpty
        ? 'Recipe ${state.recipeId}'
        : state.recipeName;
    Widget primary = _DarkroomViewport(
      state: state,
      onRerender: _controller.refreshRender,
    );
    if (compareId != null) {
      final branches = ref.watch(
        darkroomBranchControllerProvider(
          DarkroomBranchScope(
            masterPath: state.baseMasterPath,
            recipeId: state.recipeId,
          ),
        ),
      );
      final other = branches.branchFor(compareId);
      primary = _DarkroomCompareView(
        aState: state,
        aLabel: aLabel,
        bRecipeId: compareId,
        bLabel: other?.label ?? 'Recipe $compareId',
        bIsAutopilotDraft: other?.author == RecipeAuthor.autopilot,
        mode: _compareMode,
      );
    }

    return AdaptivePanelLayout(
      // Segmented, not a bottom sheet: the history stack is a scrolling list of
      // cards with their own controls, and a peeking sheet would leave the
      // operator dragging a sheet up and down to reach a slider. On a phone the
      // three regions reflow into three full-width views instead.
      phoneStrategy: PhonePanelStrategy.segmented,
      primarySegmentLabel: compareId == null ? 'Image' : 'A | B',
      primarySegmentIcon:
          compareId == null ? SkotiqIcons.image : SkotiqIcons.layers,
      initialPanelWidth: 360,
      minPanelWidth: 280,
      maxPanelWidth: 520,
      primary: primary,
      // One strip over whichever panels are on screen, drawn by the layout that
      // knows how many surfaces that is. See [_compareOwner].
      secondaryHeader:
          compareId == null ? null : _compareOwner(colors, aLabel: aLabel),
      secondary: [
        AdaptivePanel(
          title: compareId == null ? 'Recipe' : 'Recipe · A',
          icon: SkotiqIcons.sliders,
          child: _DarkroomRecipePanel(
            state: state,
            onUndo: _controller.undo,
            onRedo: _controller.redo,
            onResetToLinear: _controller.resetToLinear,
            onRerender: _controller.refreshRender,
          ),
        ),
        AdaptivePanel(
          title: compareId == null ? 'History' : 'History · A',
          icon: SkotiqIcons.layers,
          child: _DarkroomHistoryPanel(
            state: state,
            onToggle: _controller.toggleStep,
            onParamChanged: _controller.setParam,
            onRemove: _controller.removeStep,
            onReorder: _controller.reorderStep,
            onInsert: _controller.insertStep,
          ),
        ),
      ],
    );
  }

  /// Name the branch a secondary panel is showing, while a compare is armed.
  ///
  /// Both panels render the A recipe — A is the open editor, B is rendered from
  /// its own row and is not editable here — and while comparing they said so
  /// nowhere. A stack of four steps sat beside two panes captioned "A · …" and
  /// "B · …" belonging, as far as anything on screen or in the accessibility
  /// tree went, to neither: the one question the compare exists to answer had
  /// an unlabelled answer.
  ///
  /// Labelled at this seam because the panel titles do not reach a desktop
  /// screen reader — [AdaptivePanelLayout] renders them only on the phone
  /// segments — so the sentence has to be inside the panel column to be read.
  ///
  /// Handed to the layout's `secondaryHeader` slot rather than wrapped around
  /// each panel's body. Wrapped, it was built twice — once for Recipe, once for
  /// History — and on desktop, where both panels stack in ONE column, the
  /// operator read the same strip twice and a screen reader walked two
  /// identical nodes. The layout is the only thing that knows how many
  /// secondary surfaces are on screen, so it is the thing that draws the strip
  /// once per surface.
  Widget _compareOwner(
    SkotiqColors colors, {
    required String aLabel,
  }) {
    return Semantics(
      key: const ValueKey('darkroom_compare_owner'),
      container: true,
      label: 'Showing pane A, $aLabel. These are pane A\'s steps; pane B '
          'renders its own recipe and is not edited here.',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceMd,
          vertical: SkotiqTokens.spaceSm,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(bottom: BorderSide(color: colors.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              // "Pane A · …", not the pane's own "A · …" caption: this strip is
              // read beside that caption, and repeating it word for word would
              // leave the two indistinguishable to anyone searching the screen
              // for which one owns the stack.
              'Pane A · $aLabel',
              style: SkotiqTypography.labelStrongSm.copyWith(
                color: colors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'B renders its own recipe and is not edited here.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Open the export sheet over the stack as it stands.
  ///
  /// The steps handed over are the EDITED ones, unsaved changes included, so
  /// the file matches the picture the operator is looking at rather than the
  /// last state that reached the recipe row.
  void _openExportSheet(DarkroomState state) {
    final recipeId = state.recipeId;
    if (recipeId == null) return;
    // What the viewport is showing, when what it is showing is that the base
    // master itself cannot be read. The export replays the stack over that same
    // file, so the sheet opens already knowing it cannot succeed.
    final renderError = state.renderError;
    final masterFailure = renderError != null &&
            darkroomMasterFailureNextStep(renderError, state.baseMasterPath) !=
                null
        ? renderError
        : null;
    unawaited(
      _DarkroomExportSheet.show(
        context,
        recipeId: recipeId,
        recipeName:
            state.recipeName.isEmpty ? 'Recipe $recipeId' : state.recipeName,
        baseMasterPath: state.baseMasterPath,
        author: state.author,
        steps: state.steps,
        catalog: state.catalog,
        reports: state.reports,
        catalogStars: _controller.catalogStars,
        baseMasterFailure: masterFailure,
        // The engine's verdict on the recipe as stored — the same steps this
        // sheet sends. `recipeError`, not `blockingRecipeError`: the panel's
        // sentence is scoped to the steps a RENDER replays, and the render
        // leaves out a switched-off step this build cannot run, while an export
        // sends the stack whole and is refused by it.
        recipeRefusal: state.recipeError,
      ),
    );
  }
}

/// The way out of the "nothing to open" empty state, labelled with where it
/// actually goes.
///
/// It said "Back to session review" and went to Analytics > History — the
/// session LIST, a different screen, showing every night rather than this
/// master's. Two facts were wrong at once: the destination, and the word "back"
/// over a screen the operator may never have been on.
///
/// So the master's own session is resolved first, through the fold record that
/// is the only thing joining a master to a night, and the label is written from
/// the answer:
///
///  * a resolved session — the button says "session review" and opens THAT
///    night's review;
///  * no session, or no master to ask about (a recipe row that is gone names
///    none) — the button says it is opening the session list, which is where it
///    goes.
///
/// Resolved on build rather than on press, because the label is the promise: a
/// control that discovers where it can go only after being pressed is the same
/// defect one screen further on.
class _DarkroomFailureExit extends ConsumerStatefulWidget {
  /// What the route asked for. Its master id is the only handle this state has
  /// — the load failed, so the controller carries no master of its own.
  final DarkroomScope scope;

  const _DarkroomFailureExit({required this.scope});

  @override
  ConsumerState<_DarkroomFailureExit> createState() =>
      _DarkroomFailureExitState();
}

class _DarkroomFailureExitState extends ConsumerState<_DarkroomFailureExit> {
  /// The session this master belongs to, once the walk has answered. Null both
  /// before the answer and when the answer is "there is none" — [_resolved]
  /// tells the two apart.
  int? _sessionId;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final masterId = widget.scope.masterId;
    if (masterId == null) {
      if (mounted) setState(() => _resolved = true);
      return;
    }
    int? sessionId;
    try {
      sessionId = await resolveSessionForDarkroomMaster(ref, masterId);
    } catch (error) {
      // The list route is the honest fallback: a database that cannot answer
      // which night this master came from has not proved there is no night, so
      // the button stops claiming to know which one and says what it will open.
      developer.log(
        'The Darkroom could not resolve the session behind master $masterId, '
        'so its way out offers the session list instead',
        name: 'DarkroomScreen',
        level: 900,
        error: error,
      );
      sessionId = null;
    }
    if (!mounted) return;
    setState(() {
      _sessionId = sessionId;
      _resolved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = _sessionId;
    // Until the walk answers, the button offers the destination it is certain
    // of. It never promises a review it has not found.
    if (!_resolved || sessionId == null) {
      return SkotiqButton(
        label: 'Browse sessions',
        icon: SkotiqIcons.history,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        semanticsHint:
            'Opens the session list in Analytics. This master has no '
            'session review to open.',
        onPressed: () => context.go('/analytics?tab=history'),
      );
    }
    return SkotiqButton(
      label: 'Open this night\'s session review',
      icon: SkotiqIcons.history,
      variant: ButtonVariant.secondary,
      size: ButtonSize.small,
      onPressed: () => context.go(sessionReviewLocation(sessionId)),
    );
  }
}

/// The two ways to give a master its first recipe.
///
/// Both are offered rather than one being taken automatically: a draft is the
/// registry's interpretation of these pixels, and starting from the linear
/// master is the operator saying they want to make every call themselves.
class _DarkroomStartOfferView extends StatelessWidget {
  final DarkroomStartOffer offer;
  final bool busy;
  final String? error;

  /// The other masters of the same night, so the offer says the night produced
  /// more than the one master this route resolved to.
  final List<DarkroomSiblingDraft> siblings;

  /// Why the night's other masters could not be listed.
  final String? siblingsError;

  final VoidCallback onStartFromLinear;
  final VoidCallback onDraftForMe;

  /// The third way to give a master a recipe: read one back out of a
  /// `.skrecipe` sidecar an export wrote.
  final VoidCallback onImportRecipe;

  /// Put the standing import refusal away.
  ///
  /// The same callback the editor layout hands its copy of this alert: both
  /// layouts render the one `offerError` field, so clearing it here is the same
  /// act as clearing it there.
  final VoidCallback onDismissError;

  const _DarkroomStartOfferView({
    required this.offer,
    required this.busy,
    required this.error,
    required this.siblings,
    required this.siblingsError,
    required this.onStartFromLinear,
    required this.onDraftForMe,
    required this.onImportRecipe,
    required this.onDismissError,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final message = error;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EmptyState(
                icon: SkotiqIcons.palette,
                title: '${offer.masterName} has no recipe yet',
                body: 'This linear master is ${offer.width}×${offer.height}, '
                    '${offer.channels} channel${offer.channels == 1 ? '' : 's'}. '
                    'Nothing interpretive has been applied to it. Choose where '
                    'to start — either way the master itself is untouched.',
              ),
              if (message != null) ...[
                const SizedBox(height: SkotiqTokens.spaceMd),
                // Dismissible, exactly as the editor layout's copy is: this
                // alert takes ~46 pixels above the three start buttons and
                // stood until another import replaced it, so a refusal the
                // operator had finished reading kept moving the controls it
                // was telling them to use.
                SkotiqBanner(
                  title: 'That recipe file was not imported',
                  key: const ValueKey('darkroom_import_refusal'),
                  tone: BannerTone.error,
                  message: message,
                  onDismiss: onDismissError,
                ),
              ],
              const SizedBox(height: SkotiqTokens.spaceLg),
              SkotiqButton(
                label: 'Draft for me',
                icon: SkotiqIcons.sparkle,
                isLoading: busy,
                onPressed: busy ? null : onDraftForMe,
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                // The crop is stated as conditional because it is: the registry
                // measures the area every registered frame covers, and over a
                // stack whose frames all cover the same pixels that area is the
                // whole master, so the draft leaves the crop out and says so.
                // Promising "a crop off the registration edge" outright named a
                // step the draft does not always carry, and the operator read
                // the promise before the draft existed to contradict it.
                'The operation registry measures this master and proposes a '
                'first stack — a background fit, denoise, '
                '${offer.isColor ? 'a color calibration' : ''
                    'no color calibration, because the fit needs three '
                    'channels and this master has '
                    '${offer.channels}'}, and a stretch. A crop joins them when '
                'the registration left an edge to trim, and is left out when '
                'the frames cover the whole master. Every step arrives '
                'adjustable, and the draft states what it left out and why.',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceLg),
              SkotiqButton(
                label: 'Start from linear',
                icon: SkotiqIcons.frame,
                variant: ButtonVariant.secondary,
                onPressed: busy ? null : onStartFromLinear,
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                'An empty recipe over the master\'s own pixels. Nothing is '
                'proposed and nothing is applied until you add a step — the '
                'History stack\'s "Add step" lists every operation this build '
                'registers, with the stage each one runs in.',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceLg),
              SkotiqButton(
                label: 'Import .skrecipe',
                icon: SkotiqIcons.upload,
                variant: ButtonVariant.secondary,
                onPressed: busy ? null : onImportRecipe,
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                'Read back the sidecar an export writes beside its file. The '
                'steps arrive exactly as the file stores them, checked against '
                'this build — an operation this build does not register is '
                'kept and its card says so, rather than being dropped on the '
                'way in.',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              ..._siblingsBlock(context, colors),
            ],
          ),
        ),
      ),
    );
  }

  /// The night's other masters, stated here as well as on the branch bar.
  ///
  /// This view is where a night with four masters most often lands after a
  /// delete, and a master with no recipe carries no branch bar at all — so
  /// without this the offer is the one screen in the Darkroom that could not
  /// say the other three drafts exist.
  List<Widget> _siblingsBlock(
    BuildContext context,
    SkotiqColors colors,
  ) {
    final error = siblingsError;
    if (error != null) {
      return [
        const SizedBox(height: SkotiqTokens.spaceLg),
        SkotiqBanner(
          title: 'The night\'s other masters could not be listed',
          tone: BannerTone.info,
          message: error,
        ),
      ];
    }
    if (siblings.isEmpty) return const [];
    return [
      const SizedBox(height: SkotiqTokens.spaceLg),
      Text(
        'This night produced ${siblings.length + 1} masters. The others:',
        style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
      ),
      const SizedBox(height: SkotiqTokens.spaceXs),
      Wrap(
        spacing: SkotiqTokens.spaceXs,
        runSpacing: SkotiqTokens.spaceXs,
        children: [
          for (final sibling in siblings)
            SkotiqChip(
              label: sibling.recipeId == null
                  ? '${sibling.label} — no recipe yet'
                  : sibling.label,
              icon: darkroomSiblingIcon(sibling),
              onTap: () =>
                  context.go(darkroomEditLocation(masterId: sibling.masterId)),
            ),
        ],
      ),
    ];
  }
}

/// The strip above the editor: the way out, which image and recipe are open,
/// and the render control.
///
/// The Darkroom's own header names the screen and its tabs, so this strip
/// carries what the header used to qualify the title with: the image (its
/// target and kind as an overline) and the recipe open over it.
class _DarkroomEditorBar extends StatelessWidget {
  /// The registered image, once the library has answered.
  final DarkroomLibraryImage? image;

  /// The open recipe's name, or null while there is no recipe.
  final String? recipeName;

  /// The image's name from the start offer, for an image with no recipe.
  final String? offerName;

  final Widget back;
  final Widget? action;

  const _DarkroomEditorBar({
    required this.image,
    required this.recipeName,
    required this.offerName,
    required this.back,
    required this.action,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final image = this.image;
    final imageName = image?.master.name ?? offerName;
    final overline = image == null
        ? null
        : [
            image.target,
            image.kind,
            if (image.master.width > 0)
              '${image.master.width}×${image.master.height}',
          ].join(' · ').toUpperCase();
    // The overline already names the target and the kind, so the title is the
    // open recipe, or the image itself while it has none.
    final recipe = recipeName;
    final title =
        recipe != null && recipe.isNotEmpty ? recipe : (imageName ?? '');
    return Container(
      key: const ValueKey('darkroom_editor_bar'),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          back,
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (overline != null)
                  Text(
                    overline,
                    style: kDarkroomOverline.copyWith(color: colors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (title.isNotEmpty)
                  Text(
                    title,
                    style: SkotiqTypography.bodyStrong.copyWith(
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: SkotiqTokens.spaceMd),
            // Its own node: a header action merged into the bar's words read
            // as one button named after the image.
            Semantics(container: true, child: action),
          ],
        ],
      ),
    );
  }
}
