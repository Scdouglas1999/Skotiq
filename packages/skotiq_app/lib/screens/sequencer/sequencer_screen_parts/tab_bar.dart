part of '../sequencer_screen.dart';

/// The screen's 56 px [PageHeader]: `list-ordered` · "Sequencer" · underline
/// tabs · Preflight + the run's transport button (06 §Sequencer).
///
/// The old strip carried a title row, a keyboard-shortcut icon button and a
/// "Sequence Running" chip. Shortcuts moved to the top bar's help popover and
/// the run state is the instrument bar's job, so neither is rebuilt here: the
/// header holds exactly the screen name, its tabs, and the action the operator
/// came for.
class _SequencerPageHeader extends ConsumerWidget {
  const _SequencerPageHeader({
    required this.controller,
    required this.executionState,
    required this.isPhone,
  });

  final TabController controller;

  /// The run's live state. Drives which transport button the header offers
  /// (Start, or Pause/Resume + Stop) — never a status chip.
  final SequenceExecutionState executionState;

  /// Form-factor decision computed once at the screen level so the header and
  /// the body agree on phone-vs-desktop.
  final bool isPhone;

  /// Tutorial keys keyed by tab so the strip stays in sync with the
  /// [SequencerTab] enum that drives the controller.
  static Key? _buttonKeyFor(SequencerTab tab) {
    switch (tab) {
      case SequencerTab.builder:
        return SequencerTutorialKeys.tabBuilder;
      case SequencerTab.templates:
        return SequencerTutorialKeys.tabTemplates;
      case SequencerTab.sequences:
      case SequencerTab.history:
        return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final validation = ref.watch(liveValidationProvider);
    final actionService = ref.read(sequenceActionServiceProvider);

    Future<void> run(Future<CommandActionResult> Function() action) async {
      final result = await action();
      if (!context.mounted) return;
      context.showCommandActionResult(result);
    }

    void openPreflight({bool armed = false}) {
      showDialog<void>(
        context: context,
        builder: (_) => PreFlightValidationDialog(
          onStartSequence: armed ? () => run(actionService.start) : null,
        ),
      );
    }

    // Derive the strip from the single SequencerTab enum so adding a tab there
    // updates the controller length and this strip in one edit. Desktop
    // surfaces the Alt+1..4 accelerators in the semantic label; phones have no
    // keyboard so the hint is omitted.
    final tabs = <AdaptiveTab>[
      for (final tab in SequencerTab.values)
        AdaptiveTab(
          label: tab.label,
          buttonKey: _buttonKeyFor(tab),
          semanticLabel:
              isPhone ? tab.label : '${tab.label} (Alt+${tab.index + 1})',
        ),
    ];

    final blocking = validation.errorCount + validation.warningCount;

    return PageHeader(
      icon: SkotiqIcons.listOrdered,
      title: context.l10n.text('navSequencer'),
      tabs: AnimatedBuilder(
        // Rebuild the strip when the controller's selection changes so the
        // underline and the scroll-into-view follow the active index whether
        // the change came from a tap, a keyboard shortcut, or the
        // provider->controller sync in initState.
        animation: controller.animation ?? controller,
        builder: (context, _) => AdaptiveTabBar(
          tabs: tabs,
          selectedIndex: controller.index,
          horizontalPadding: 0,
          onSelected: controller.animateTo,
        ),
      ),
      actions: <Widget>[
        // A phone header has room for a title and one glyph. The words go, not
        // the action: the tooltip keeps the name and MobilePlaybackBar — right
        // under this header — already owns the transport, so repeating
        // Start/Stop here would be the second copy of the same control.
        if (isPhone)
          SkotiqIconButton(
            icon: LucideIcons.listChecks,
            tooltip: 'Preflight',
            onPressed: openPreflight,
          )
        else
          SkotiqButton(
            label: 'Preflight',
            icon: LucideIcons.listChecks,
            variant: ButtonVariant.ghost,
            onPressed: openPreflight,
          ),
        // The count rides beside the button rather than inside it: a chip is
        // not one of SkotiqButton's slots, and inventing a local
        // button-with-badge would be a second button style on the page.
        if (blocking > 0)
          Semantics(
            button: true,
            enabled: true,
            label: countLabel(blocking, 'preflight issue'),
            child: ExcludeSemantics(
              child: SkotiqChip(
                label: '$blocking',
                tone: validation.hasErrors ? ChipTone.error : ChipTone.warning,
                onTap: openPreflight,
              ),
            ),
          ),
        if (!isPhone)
          ..._transportActions(
            executionState: executionState,
            onStart: () => openPreflight(armed: true),
            onPause: () => run(actionService.pause),
            onResume: () => run(actionService.resume),
            onStop: () => run(actionService.stop),
          ),
      ],
    );
  }

  /// The header's transport: `start` "Start" while idle, `destructive` "Stop"
  /// plus `secondary` "Pause"/"Resume" once the executor owns the tree.
  ///
  /// Skip and Reset are deliberately absent — they belong to a run in flight,
  /// not to the page. They live on in the canvas bar's overflow menu, so no
  /// capability is lost.
  static List<Widget> _transportActions({
    required SequenceExecutionState executionState,
    required VoidCallback onStart,
    required VoidCallback onPause,
    required VoidCallback onResume,
    required VoidCallback onStop,
  }) {
    if (!executionState.canStop) {
      return <Widget>[
        SkotiqButton(
          label: 'Start',
          icon: LucideIcons.play,
          variant: ButtonVariant.start,
          onPressed: executionState.canStart ? onStart : null,
          semanticsHint: executionState.canStart
              ? null
              : 'The sequence is finishing the last command.',
        ),
      ];
    }
    return <Widget>[
      if (executionState.canPause)
        SkotiqButton(
          label: 'Pause',
          icon: LucideIcons.pause,
          variant: ButtonVariant.secondary,
          onPressed: onPause,
        )
      else if (executionState.canResume)
        SkotiqButton(
          label: 'Resume',
          icon: LucideIcons.play,
          variant: ButtonVariant.secondary,
          onPressed: onResume,
        ),
      SkotiqButton(
        label: 'Stop',
        icon: LucideIcons.square,
        variant: ButtonVariant.destructive,
        onPressed: onStop,
      ),
    ];
  }
}
