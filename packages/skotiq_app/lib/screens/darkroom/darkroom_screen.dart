/// The Darkroom editor: a linear master on the left, the recipe that
/// interprets it on the right.
///
/// The screen is one rendering of one [DarkroomController] state. Nothing here
/// touches pixels or the recipe engine directly — the controller owns the
/// render loop and every native call goes through `DarkroomSeam`, so this file
/// only decides what the operator sees and which controller method a gesture
/// calls.
///
/// Reached as `/darkroom?recipe=<id>` (a recipe by row id) or
/// `/darkroom?master=<id>` (a master, whose newest recipe opens — or, when it
/// has none, an offer to create one).
library;

import 'dart:async';
import 'dart:convert';
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
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../widgets/red_night_filter.dart';
import 'package:path/path.dart' as p;

import '../../utils/darkroom_navigation.dart';
import '../../utils/exported_file_reveal.dart';
import '../stack_result/stack_and_share_dialog.dart'
    show describeStackShareFailure;
import 'darkroom_branch_controller.dart';
import 'darkroom_controller.dart';

part 'darkroom_screen_parts/_landing.dart';
part 'darkroom_screen_parts/_image_surface.dart';
part 'darkroom_screen_parts/_viewport.dart';
part 'darkroom_screen_parts/_history_panel.dart';
part 'darkroom_screen_parts/_add_step.dart';
part 'darkroom_screen_parts/_recipe_panel.dart';
part 'darkroom_screen_parts/_branch_bar.dart';
part 'darkroom_screen_parts/_compare.dart';
part 'darkroom_screen_parts/_export_sheet.dart';

/// The Darkroom editor screen.
class DarkroomScreen extends ConsumerStatefulWidget {
  /// What the route asked to open.
  final DarkroomScope scope;

  const DarkroomScreen({super.key, required this.scope});

  @override
  ConsumerState<DarkroomScreen> createState() => _DarkroomScreenState();
}

class _DarkroomScreenState extends ConsumerState<DarkroomScreen> {
  /// The attempt number of the refusal this screen has already announced, so a
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
  void didUpdateWidget(covariant DarkroomScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scope != oldWidget.scope) {
      // Switching branches replaces the A side, and the B side was chosen
      // against the recipe that is no longer open. Keeping it would leave a
      // compare whose labels describe a pairing the operator never asked for.
      _compareRecipeId = null;
      _lastShownRefusal = 0;
      _lastShownInsertRefusal = 0;
      _lastShownSaveError = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (ref.watch(isRemoteClientProvider)) {
      // The Darkroom renders a linear master FITS through the native recipe
      // engine, and both the file and the engine live on the imaging host. A
      // remote client has neither, so there is nothing here it could render —
      // and a client-local recipe row would be a second, divergent history of
      // a master it cannot see.
      //
      // Gated on the client ROLE, not on the connection, exactly as Delivery
      // settings is. A desktop launched with `--remote-host` that has not
      // reached its rig yet has a `Disconnected` backend, not a
      // `NetworkBackend`: `backend is NetworkBackend` read false for the whole
      // pre-handshake window and after every drop, so the full editor opened
      // over the client's OWN database — recipes no dawn job on the rig will
      // ever read — while Delivery on the same launch correctly refused.
      //
      // Reached by deep link now that every in-app control refuses first, so it
      // is a screen an operator lands on with no route in mind — which is why
      // it takes the same shell as the editor. Returning its own Scaffold here
      // put it OUTSIDE the shortcuts and the header actions below: no Back, no
      // action on the empty state, and Escape and Alt+Left both dead, on the
      // one branch whose whole job is to send the operator somewhere else.
      return _shell(
        colors: colors,
        context: 'Host-only processing',
        actions: [_backControl(savePending: false)],
        body: EmptyState(
          icon: SkotiqIcons.device,
          title: 'Open the Darkroom on the imaging host',
          body: 'Linear masters and the recipe engine that renders them live '
              'on the imaging computer. Open Skotiq there to adjust, '
              'reorder, or export a recipe. Remote Darkroom editing is '
              'unavailable in this release.',
          action: SkotiqButton(
            key: const ValueKey('darkroom_remote_gate_back'),
            label: 'Go back',
            icon: SkotiqIcons.arrowLeft,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: _leave,
          ),
        ),
      );
    }

    // A bare `/darkroom` is now a rail destination, so it lists what there is
    // to open instead of refusing. Deliberately BEFORE the controller is
    // watched: an empty scope fails that load by design, and watching it would
    // put "this link named neither a recipe nor a master" back on screen.
    if (widget.scope.isEmpty) {
      return Scaffold(
        backgroundColor: colors.background,
        body: const SafeArea(bottom: false, child: _DarkroomLandingView()),
      );
    }

    final state = ref.watch(darkroomControllerProvider(widget.scope));

    // A refused reorder and a failed write are both things the operator did
    // that did not take effect, so each is announced once per OCCURRENCE — the
    // attempt the controller stamped on it, not the words it carries. Deduping
    // on the words made a second press of the same enabled control, refused for
    // the same reason, produce nothing at all: the sentence matched the one
    // already shown, so the toast was suppressed and the operator's second
    // attempt went unacknowledged.
    if (state.reorderRefusal == null) {
      _lastShownRefusal = 0;
    } else if (state.reorderRefusalAttempt != _lastShownRefusal) {
      _lastShownRefusal = state.reorderRefusalAttempt;
      _toast(state.reorderRefusal!, SkotiqAlertSeverity.warning);
    }
    // Announced as well as printed, for the same reason: the chooser closes on
    // the choice, so a refused insert leaves a stack that looks untouched and
    // an alert one panel away from where the operator was looking.
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

    return _shell(
      colors: colors,
      // The recipe qualifies the title; it does not replace it. The header used
      // to become the recipe's name, which left the one screen in the app whose
      // header did not say which screen it was.
      context: state.hasRecipe ? state.recipeName : null,
      actions: _headerActions(state),
      body: _body(context, colors, state),
    );
  }

  /// The screen every branch of this route renders inside.
  ///
  /// The Darkroom is a PUSHED route with no destination of its own on the nav
  /// rail: the rail keeps highlighting whatever the operator came from, and
  /// until this binding existed the only way out was to press a different rail
  /// destination — Escape and Alt+Left both did nothing at all, which reads as
  /// a broken window rather than as a screen with no back. The rail's claim
  /// becomes true once leaving returns to what it is pointing at.
  ///
  /// Every branch, because a branch that opted out of the shell opted out of
  /// the whole way-out contract at the same time.
  Widget _shell({
    required SkotiqColors colors,
    required String? context,
    required List<Widget> actions,
    required Widget body,
  }) {
    return Scaffold(
      backgroundColor: colors.background,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _leave,
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _leave,
        },
        child: Focus(
          autofocus: true,
          // Publishing this node annotates the whole screen as a focusable
          // control with no enabled state, which the AT-SPI bridge reports as a
          // disabled button wrapping the editor — the same trap the export
          // sheet's own Escape host documents.
          includeSemantics: false,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                PageHeader(
                  title: 'Darkroom',
                  icon: SkotiqIcons.aperture,
                  context: context,
                  actions: actions,
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Leave the Darkroom the way it was entered.
  ///
  /// Popping is what a pushed route deserves: it returns to the screen the nav
  /// rail is still highlighting. A Darkroom reached by a deep link has nothing
  /// to pop to, and goes to the session review — the same destination the
  /// screen's own empty state offers, because that is the surface that lists
  /// the masters there are pixels for.
  ///
  /// Nothing is refused and nothing is lost on the way out. A render inside the
  /// engine is asked to stop by the controller's own dispose, and a debounced
  /// edit that has not reached the recipe row is issued there too; the back
  /// control says which of those is happening rather than blocking on it.
  void _leave() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
      return;
    }
    context.go('/analytics?tab=history');
  }

  /// The way out, in the header.
  ///
  /// [savePending] is stated on the control itself, because it is the state
  /// that decides what leaving does: the pending write is issued by the
  /// controller's dispose, and an operator who cannot see that a write is
  /// outstanding has no way to know whether leaving costs them the edit. The
  /// host-only branch has no controller and therefore nothing outstanding.
  Widget _backControl({required bool savePending}) {
    final pending = savePending
        ? 'Back — this edit is still being written to the recipe, and leaving '
            'issues that write'
        : 'Back to where the Darkroom was opened from';
    return Semantics(
      container: true,
      button: true,
      enabled: true,
      label: pending,
      excludeSemantics: true,
      onTap: _leave,
      child: Tooltip(
        message: '$pending. Escape and Alt+Left do the same.',
        child: SkotiqButton(
          label: 'Back',
          icon: SkotiqIcons.arrowLeft,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: _leave,
        ),
      ),
    );
  }

  /// The header's action slot: the way out, and the render control.
  List<Widget> _headerActions(DarkroomState state) {
    final render = _headerAction(state);
    return [
      _backControl(savePending: state.savePending),
      // The same boundary the Back control carries, for the same reason. The
      // `CallbackShortcuts` above publishes one focusable node over the whole
      // screen, and every unbounded fragment under it merges in — so in a
      // layout whose BODY offers no competing action, this one's tap and role
      // landed on the node holding the header's own words: the start offer
      // reached AT-SPI as a single button named "Darkroom / No recipe yet /
      // Reload", with the screen's title readable only as part of a control's
      // name. The editor layout escaped it purely because its body has
      // actions of its own to be incompatible with.
      if (render != null) Semantics(container: true, child: render),
    ];
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
        siblings: state.siblings,
        siblingsError: state.siblingsError,
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
        ),
        // The branch bar's `Import .nsrecipe` writes its refusals into
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
  /// `.nsrecipe` sidecar an export wrote.
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
                '${offer.isColor ? 'a colour calibration' : ''
                    'no colour calibration, because the fit needs three '
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
                label: 'Import .nsrecipe',
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
              onTap: () => context.go(darkroomMasterLocation(sibling.masterId)),
            ),
        ],
      ),
    ];
  }
}
