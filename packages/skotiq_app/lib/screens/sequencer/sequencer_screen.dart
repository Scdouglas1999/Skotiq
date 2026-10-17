import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';
import '../../models/command_action_result.dart';
import '../../services/sequence_action_service.dart';
import '../../utils/count_label.dart';
import '../../utils/sequence_mutator_helper.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/animated_tab_bar_view.dart';
import '../../widgets/tutorial_keys/sequencer_keys.dart';
import 'run_status_presentation.dart';
import 'widgets/batch_operations_toolbar.dart';
import 'widgets/delete_node_confirmation.dart';
import 'widgets/palette_copy.dart';
import 'widgets/palette_icon_map.dart';
import 'widgets/preflight_validation_dialog.dart';
import 'widgets/sequence_toolbar.dart';
import 'widgets/node_palette.dart';
import 'widgets/node_palette_empty_state.dart';
import 'widgets/node_palette_search.dart';
import 'widgets/snippet_palette.dart';
import 'widgets/sequence_tree.dart';
import 'widgets/node_properties_panel.dart';
import 'widgets/node_progress_panels.dart';
import 'widgets/notes_panel.dart';
import 'widgets/sequence_progress_bar.dart';
import 'widgets/session_report_dialog.dart';
import 'widgets/equipment_telemetry_strip.dart';
import 'widgets/mobile_playback_bar.dart';
import 'widgets/target_queue_panel.dart';
import 'tabs/history_tab.dart';
import 'tabs/sequence_library_tab.dart';
import 'tabs/templates_tab.dart';

part 'sequencer_screen_parts/tab_bar.dart';
part 'sequencer_screen_parts/builder_layout.dart';
part 'sequencer_screen_parts/toolbox_panel.dart';
part 'sequencer_screen_parts/node_palette.dart';
part 'sequencer_screen_parts/snippet_palette.dart';
part 'sequencer_screen_parts/collapsible_panel.dart';
part 'sequencer_screen_parts/narrow_layout.dart';
part 'sequencer_screen_parts/mobile_layout.dart';

/// Canonical route path for the sequencer screen.
///
/// Referenced by the router's [GoRoute] and the shell's run-overlay-visibility
/// check so the two cannot drift via a copy-pasted `'/sequencer'` string
/// literal.
const String kSequencerRoutePath = '/sequencer';

/// The top-level sequencer tabs, in display order.
///
/// Single source of truth for both the [TabController] length and the
/// [AdaptiveTabBar] strip — adding a tab here updates the controller, the
/// strip and the keyboard accelerator hints in one edit.
enum SequencerTab {
  builder('Builder', LucideIcons.workflow),
  templates('Templates', LucideIcons.fileStack),
  sequences('Saved', LucideIcons.folderOpen),
  history('History', LucideIcons.history);

  const SequencerTab(this.label, this.icon);

  /// Visible tab label.
  final String label;

  /// Leading icon used in the strip + collapsed (icon-only) phone mode.
  final IconData icon;
}

/// Map a sequencer `?tab=` deep link to the canonical tab enum.
SequencerTab? sequencerTabFromQuery(String? value) {
  if (value == null) return null;
  switch (value.toLowerCase()) {
    case 'builder':
      return SequencerTab.builder;
    case 'templates':
      return SequencerTab.templates;
    case 'sequences':
    case 'library':
      return SequencerTab.sequences;
    case 'history':
    case 'runs':
      return SequencerTab.history;
  }
  return null;
}

/// The tabs inside the desktop toolbox panel, in display order.
///
/// A tab selection rather than a visibility flag, so Ctrl+T always has a
/// visible effect even when the user is on the Targets tab.
enum SequencerToolboxTab { nodes, snippets, targets }

/// Currently selected sequencer tab.
final sequencerTabProvider =
    StateProvider<int>((ref) => SequencerTab.builder.index);

/// Whether the toolbox panel is collapsed (icon-only mode).
///
/// Seeded once from the persisted [AppSettingsState] panel preference (when
/// present) and written back through the setter on every toggle. Until the
/// core settings field lands (see the area's modelChangeRequests) this falls
/// back to an in-session [StateProvider], which still survives rebuilds /
/// navigation within a session.
final sequencerToolboxCollapsedProvider = StateProvider<bool>((ref) => false);

/// Whether the properties panel is collapsed (icon-only mode).
final sequencerPropertiesCollapsedProvider =
    StateProvider<bool>((ref) => false);

/// "Show me the toolbox anyway", set when the operator opens a pane the narrow
/// layout had auto-collapsed.
///
/// The desktop builder derives a collapse when the canvas would be squeezed.
/// That derived collapse is a good DEFAULT and a bad verdict: with an effective
/// state of `pref || derived`, the toggle icons flip a preference that can never
/// win, leaving no palette and no Target Settings and no escape short of
/// resizing the window. This override is how the operator overrules it, and it
/// is cleared the moment they collapse the pane again.
final sequencerToolboxForceOpenProvider = StateProvider<bool>((ref) => false);

/// "Show me the properties anyway" — see [sequencerToolboxForceOpenProvider].
final sequencerPropertiesForceOpenProvider =
    StateProvider<bool>((ref) => false);

/// Which toolbox sub-tab is active (Nodes / Snippets / Targets).
///
/// Drives the toolbox [TabController] index. Persisted in-session; the
/// modelChangeRequests record the optional cross-restart settings field.
final sequencerToolboxTabProvider =
    StateProvider<SequencerToolboxTab>((ref) => SequencerToolboxTab.nodes);

/// Backwards-compatible "reveal the snippets palette" trigger.
///
/// [sequencerToolboxTabProvider] owns the toolbox tab. One cross-area caller
/// (Templates tab → "Go to Builder") flips this to `true` to surface snippets,
/// so it stays a *write-only intent flag* that the toolbox panel bridges
/// one-way into the enum (setting it back to false after acting). There is no
/// bidirectional coupling.
final snippetPaletteVisibleProvider = StateProvider<bool>((ref) => false);

/// User-dragged width of the desktop left (toolbox) panel, or null to fall
/// back to the derived responsive width. Persisted in-session so a drag does
/// not snap back on the next layout pass.
final sequencerLeftPanelWidthProvider = StateProvider<double?>((ref) => null);

/// User-dragged width of the desktop right (properties) panel.
final sequencerRightPanelWidthProvider = StateProvider<double?>((ref) => null);

/// Flattened (item, categoryName) pairs derived from [nodePaletteProvider]
/// for the narrow-desktop icon rail.
///
/// Hoisting the flattening here means it recomputes only when the palette
/// itself changes, not on every rail rebuild (window resize / hover). The
/// category *name* is carried (not a resolved [Color]) so the per-row color
/// can be resolved from the live [SkotiqColors] in the item builder
/// without coupling this provider to the widget tree's theme.
final flatNodePaletteProvider =
    Provider<List<({NodePaletteItem item, String categoryName})>>((ref) {
  final categories = ref.watch(nodePaletteProvider);
  return [
    for (final cat in categories)
      for (final item in cat.items) (item: item, categoryName: cat.name),
  ];
});

// Note: confirm-then-delete now lives in
// `widgets/delete_node_confirmation.dart`. The Delete-key handler below
// routes through that helper so the keyboard path can't drift from the
// tree's trash-icon and right-click "Delete" paths — every
// user-initiated delete must share one policy.

class SequencerScreen extends ConsumerStatefulWidget {
  const SequencerScreen({super.key, this.initialTabQuery});

  /// Raw router `?tab=` value. Unknown values preserve the last in-session tab.
  final String? initialTabQuery;

  @override
  ConsumerState<SequencerScreen> createState() => _SequencerScreenState();
}

class _SequencerScreenState extends ConsumerState<SequencerScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    final persistedIndex = ref.read(sequencerTabProvider);
    final safePersistedIndex =
        persistedIndex >= 0 && persistedIndex < SequencerTab.values.length
            ? persistedIndex
            : SequencerTab.builder.index;
    final initialIndex = sequencerTabFromQuery(widget.initialTabQuery)?.index ??
        safePersistedIndex;
    _tabController = TabController(
      length: SequencerTab.values.length,
      initialIndex: initialIndex,
      vsync: this,
    );
    if (persistedIndex != initialIndex) {
      ref.read(sequencerTabProvider.notifier).state = initialIndex;
    }
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        ref.read(sequencerTabProvider.notifier).state = _tabController.index;
      }
    });

    // Sync provider -> controller via a listen hook rather than peeking at
    // the provider during build(). A build-time animateTo() also fires under
    // window-resize storms / hot-reload, which flickers.
    ref.listenManual<int>(sequencerTabProvider, (prev, next) {
      if (!mounted) return;
      if (_tabController.index != next) {
        _tabController.animateTo(next);
      }
    });

    // Auto-open the end-of-session report dialog (Feature A) when a run FULLY
    // finalizes. We react to the executor's one-shot terminal-run result rather
    // than to a raw state transition: the result is published exactly once —
    // AFTER durable cleanup has finished and (correctly) cleared the live run /
    // session id providers — and carries an immutable SNAPSHOT of those ids, so
    // the report and its run-scoped Journal resolve against the completed run
    // instead of racing the just-cleared providers. `listenManual` only fires on
    // changes, so a fresh screen mount never reopens an already-consumed report.
    ref.listenManual<SequenceTerminalRunResult?>(
        sequenceTerminalRunResultProvider, (prev, next) {
      if (!mounted) return;
      // Ignore the reset-to-null the next run's start publishes, and any
      // duplicate of an already-handled generation (belt-and-braces against a
      // re-publish); each real terminal carries a unique, monotonic generation.
      if (next == null) return;
      if (prev != null && prev.generation == next.generation) return;
      final sessionId = next.dbSessionId;
      if (sessionId == null) return;
      // The completed run's ids, captured at finalization — valid even though
      // the live currentRunId / session providers have since been cleared.
      final runId = next.runId;
      // Schedule the open after the current frame so the executor finishes
      // its state-update path before we push a new route.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // A report is only worth a modal when somebody is watching. While the
        // autopilot holds the rig (or the run that just ended was its own
        // dispatch) the next terminal result is minutes away, and a dialog per
        // run stacks a click-eating modal over whatever screen the operator is
        // on. Those queue instead.
        if (ref.read(sessionReportPresentationProvider) ==
            SessionReportPresentation.queued) {
          ref.read(pendingSessionReportsProvider.notifier).enqueue(
                PendingSessionReport(
                  sessionId: sessionId,
                  runId: runId,
                  endedAt: DateTime.now(),
                ),
              );
          final waiting = ref.read(pendingSessionReportsProvider).length;
          ref.read(uiNotificationProvider.notifier).showInfo(
                waiting == 1
                    ? 'Unattended run finished. Open it from Sequencer ▸ History.'
                    : '$waiting unattended runs finished. Open them from '
                        'Sequencer ▸ History.',
                title: 'Session report ready',
              );
          return;
        }
        SessionReportDialog.show(context, sessionId, runId: runId);
        // Fire the auto-prompt for a journal note
        // when the setting allows it (default true). We use the
        // sequencer screen as the host because (a) it owns the
        // execution-state listener that knows a run just ended and
        // (b) the report dialog opens above this same Navigator so
        // the prompt comes back into focus when the user closes the
        // report. The prompt itself is opt-out — "Don't ask again"
        // sets `notes.prompt_after_run = false`.
        _maybeShowNotesAutoPrompt(runId);
      });
    });

    // Create a default sequence if none exists — but only when it's safe to.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A remote slave MIRRORS the master's open sequence; it must never create
      // a local default (that's what the master pushes down). And on any
      // instance, only create while the execution state is editable:
      // createSequence() calls _ensureEditable and throws SequenceLockedException
      // if a run is paused/running — which, on a slave, is the mirrored master
      // state, producing the "Cannot create sequence while ... paused" error on
      // startup.
      if (ref.read(isRemoteModeProvider)) return;
      if (!ref.read(canEditSequenceProvider)) return;
      final sequence = ref.read(currentSequenceProvider);
      if (sequence == null) {
        ref.read(currentSequenceProvider.notifier).createSequence();
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// Open the post-run notes prompt when:
  ///   * The `notes.prompt_after_run` setting is true (or unset; default).
  ///   * The current sequence has a TargetHeaderNode whose name we can
  ///     attach the note to. We pick the first TargetHeader walking the
  ///     tree from the root; for sequences with no target header, we
  ///     skip the prompt rather than guess.
  ///
  /// The body is pre-filled with the run's wall-clock + frame counts so
  /// the operator can edit-and-save in one click or type a paragraph.
  Future<void> _maybeShowNotesAutoPrompt(int? runId) async {
    if (!mounted) return;
    final enabled =
        await ref.read(promptForNotesAfterRunProvider.future).catchError(
              (_) => true,
            );
    if (!enabled) return;
    if (!mounted) return;
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;
    TargetHeaderNode? primaryTarget;
    for (final node in sequence.nodes.values) {
      if (node is TargetHeaderNode) {
        primaryTarget = node;
        break;
      }
    }
    if (primaryTarget == null) return;
    final liveStats = ref.read(liveSequenceStatsProvider);
    final body = liveStats == null
        ? '_How did this run go?_'
        : buildAutoPromptNoteBody(
            sequenceName: sequence.name,
            wallClock: Duration(
                milliseconds: (liveStats.wallClockSecs * 1000).round()),
            framesCaptured: liveStats.framesCaptured,
            framesRejected: liveStats.framesRejected,
            triggerFires: liveStats.triggerFires,
            autofocusRuns: liveStats.autofocusRuns,
            meridianFlips: liveStats.meridianFlips,
          );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => NotesQuickPromptDialog(
        targetId: primaryTarget!.targetName,
        sequenceRunId: runId,
        prefilledBody: body,
        prefilledTitle: 'Run on ${DateTime.now().toLocal()}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final isRunning = executionState == SequenceExecutionState.running ||
        executionState == SequenceExecutionState.paused;
    // Tab sync runs via ref.listenManual in initState. The current value is
    // still read for the shortcut bindings below that gate behaviour to the
    // Builder tab.
    final currentTab = ref.watch(sequencerTabProvider);
    final failed = executionState == SequenceExecutionState.failed;
    final stats = failed ? ref.watch(liveSequenceStatsProvider) : null;
    final failure = failed
        ? runFailureHeadline(
              terminalCause: stats?.terminalCause,
              errors: stats?.errorMessages,
            ) ??
            ref.watch(sequenceProgressProvider).message
        : null;

    // The inspector's session memory of last-known per-node progress must
    // fold every progress update whether or not the panel is open — the
    // Activity tab only watches it when built, and a lazily-created
    // notifier would open on the post-reset empty maps.
    ref.watch(lastKnownNodeActivityProvider);

    return CallbackShortcuts(
      bindings: {
        // undo/redo/delete/duplicate/paste are mutations and MUST
        // no-op while the sequence is running: a stray Ctrl+Z
        // mid-run rolls back Dart state while Rust keeps executing
        // the old tree (split-brain). Ctrl+C (clipboard copy) and
        // Escape (clear multi-select) are NOT mutations and stay
        // enabled.
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
          if (currentTab != 0) return;
          if (!ref.read(canEditSequenceProvider)) return;
          ref.read(currentSequenceProvider.notifier).undo();
        },
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): () {
          if (currentTab != 0) return;
          if (!ref.read(canEditSequenceProvider)) return;
          ref.read(currentSequenceProvider.notifier).redo();
        },
        const SingleActivator(LogicalKeyboardKey.delete): () {
          if (currentTab != 0) return;
          if (!ref.read(canEditSequenceProvider)) return;
          final multiSelected = ref.read(multiSelectedNodeIdsProvider);
          if (multiSelected.isNotEmpty) {
            ref.read(multiSelectedNodeIdsProvider.notifier).deleteSelected();
          } else {
            final selectedId = ref.read(selectedNodeIdProvider);
            if (selectedId != null) {
              // Why: a Delete keystroke on a container with children
              // would silently nuke the subtree. Route through the
              // same confirmation helper the tree's trash button uses
              // so the keyboard path has parity.
              confirmAndDeleteSequenceNode(
                context: context,
                ref: ref,
                nodeId: selectedId,
              );
            }
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyD, control: true): () {
          if (currentTab != 0) return;
          if (!ref.read(canEditSequenceProvider)) return;
          final selectedId = ref.read(selectedNodeIdProvider);
          if (selectedId != null) {
            ref
                .read(currentSequenceProvider.notifier)
                .duplicateNode(selectedId);
          }
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (currentTab == 0) {
            final multiSelected = ref.read(multiSelectedNodeIdsProvider);
            if (multiSelected.isNotEmpty) {
              ref.read(multiSelectedNodeIdsProvider.notifier).clear();
            }
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () {
          // Ctrl+C is a clipboard read — not an edit. Stays enabled
          // during a run so users can copy a node into a snippet
          // even while the executor is busy.
          if (currentTab == 0) {
            final multiSelected = ref.read(multiSelectedNodeIdsProvider);
            if (multiSelected.isNotEmpty) {
              ref.read(multiSelectedNodeIdsProvider.notifier).copySelected();
            } else {
              // No multi-selection: fall back to the single selected
              // node so Ctrl+C works on a plain click selection.
              final selectedId = ref.read(selectedNodeIdProvider);
              if (selectedId != null) {
                ref
                    .read(multiSelectedNodeIdsProvider.notifier)
                    .copySelected(explicitIds: [selectedId]);
              }
            }
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () {
          if (currentTab != 0) return;
          if (!ref.read(canEditSequenceProvider)) return;
          final clipboard = ref.read(nodeCopyClipboardProvider);
          if (clipboard != null && clipboard.isNotEmpty) {
            ref
                .read(multiSelectedNodeIdsProvider.notifier)
                .pasteFromClipboard();
          }
        },
        const SingleActivator(LogicalKeyboardKey.digit1, alt: true): () {
          _tabController.animateTo(SequencerTab.builder.index);
        },
        const SingleActivator(LogicalKeyboardKey.digit2, alt: true): () {
          _tabController.animateTo(SequencerTab.templates.index);
        },
        const SingleActivator(LogicalKeyboardKey.digit3, alt: true): () {
          _tabController.animateTo(SequencerTab.sequences.index);
        },
        const SingleActivator(LogicalKeyboardKey.digit4, alt: true): () {
          _tabController.animateTo(SequencerTab.history.index);
        },
        // Ctrl+T (or Cmd+T on Mac) toggles the toolbox between Nodes and
        // Snippets. From the Targets tab it lands on Nodes, so the keystroke
        // always has a visible effect wherever it is pressed.
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): () {
          if (currentTab != SequencerTab.builder.index) return;
          final current = ref.read(sequencerToolboxTabProvider);
          ref.read(sequencerToolboxTabProvider.notifier).state =
              current == SequencerToolboxTab.nodes
                  ? SequencerToolboxTab.snippets
                  : SequencerToolboxTab.nodes;
        },
      },
      // A SCOPE, not a bare Focus. `CallbackShortcuts` only sees a key
      // event while primary focus sits inside its subtree, and the bare
      // Focus autofocused exactly once at mount: as soon as anything called
      // `unfocus()` (every text field does on submit / tap-away) focus
      // landed on the ROUTE's scope — an ancestor of these bindings — and
      // every advertised shortcut, including the Ctrl+Z the delete dialogs
      // point at, went dead until the user happened to click a focusable
      // control inside the screen again. An enclosing scope of our own
      // catches that unfocus, so focus falls back INTO the shortcut subtree
      // instead of out of it.
      child: FocusScope(
        autofocus: true,
        // Derive ONE form-factor decision at the screen level and thread it
        // to the tab strip so the header and the body agree.
        // We branch on the *short* side (same rule _BuilderContent uses)
        // so a phone held in landscape is treated as a phone in both the
        // strip and the content, instead of the strip (MediaQuery width)
        // and the body (short-side) disagreeing.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final shortSide = constraints.maxWidth < constraints.maxHeight
                ? constraints.maxWidth
                : constraints.maxHeight;
            final isPhone = BreakpointTokens.isPhone(shortSide);
            return Column(
              children: [
                // The screen's one 56 px page header (06 §Sequencer).
                _SequencerPageHeader(
                  controller: _tabController,
                  executionState: executionState,
                  isPhone: isPhone,
                ),

                if (failed)
                  Padding(
                    padding: SkotiqTokens.paddingMd,
                    child: SkotiqBanner(
                      title: 'Sequence failed',
                      message: failure == null
                          ? 'Open History for the recorded outcome.'
                          : runFailureMessage(failure),
                      tone: BannerTone.error,
                      action: SkotiqButton(
                        label: 'See details',
                        variant: ButtonVariant.secondary,
                        size: ButtonSize.small,
                        onPressed: () => _tabController
                            .animateTo(SequencerTab.history.index),
                      ),
                    ),
                  ),

                // Progress bar (when running)
                if (isRunning)
                  SequenceProgressBar(
                      key: SequencerTutorialKeys.progressBar, colors: colors),

                // Tab content. Each tab is lazily gated so Templates /
                // Sequences / History are not constructed (and their async
                // loads not kicked off) until the user first visits them.
                // The Builder tab is the default landing tab so
                // it builds immediately. Once visited, a tab stays built so
                // re-selecting it is instant and its scroll/async state
                // survives. AnimatedTabBarView keeps the fade/slide between
                // selections.
                Expanded(
                  child: AnimatedTabBarView(
                    controller: _tabController,
                    children: [
                      // Builder tab — the default landing tab, always built.
                      _LazyTab(
                        controller: _tabController,
                        index: SequencerTab.builder.index,
                        builder: (_) => _BuilderContent(colors: colors),
                      ),
                      // Templates tab — the merged library. Bundled
                      // read-only sample sequences live here as a "Starters"
                      // section above the saved/built-in templates, so there
                      // is no separate Samples tab.
                      _LazyTab(
                        controller: _tabController,
                        index: SequencerTab.templates.index,
                        builder: (_) => const TemplatesTab(),
                      ),
                      // Saved sequence catalog (host DB / remote list-full).
                      _LazyTab(
                        controller: _tabController,
                        index: SequencerTab.sequences.index,
                        builder: (_) => const SequenceLibraryTab(),
                      ),
                      // History tab.
                      _LazyTab(
                        controller: _tabController,
                        index: SequencerTab.history.index,
                        builder: (_) => const HistoryTab(),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Defers construction of an off-screen tab until it is first selected, then
/// keeps it built so re-selection is instant.
///
/// While unvisited it renders an empty [SizedBox.shrink] so the tab's subtree
/// — and any async loading it kicks off in `initState` (Library/History) — is
/// not created on screen entry. The instant the [controller] settles on
/// [index] (or is mid-animation toward it) the child is built and the `_seen`
/// flag latches so it never reverts to the placeholder.
class _LazyTab extends StatefulWidget {
  final TabController controller;
  final int index;
  final WidgetBuilder builder;

  const _LazyTab({
    required this.controller,
    required this.index,
    required this.builder,
  });

  @override
  State<_LazyTab> createState() => _LazyTabState();
}

class _LazyTabState extends State<_LazyTab> {
  bool _seen = false;

  @override
  void initState() {
    super.initState();
    _seen = _isCurrent;
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// True when the controller's selection is (or is animating toward) our
  /// index — `index` snaps to the target as soon as a swipe/animateTo begins.
  bool get _isCurrent => widget.controller.index == widget.index;

  void _onControllerChanged() {
    if (_seen || !_isCurrent) return;
    setState(() => _seen = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_seen) return const SizedBox.shrink();
    return widget.builder(context);
  }
}
