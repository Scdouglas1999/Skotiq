// Notice band, step rail, progress eyebrow, footers and step body dispatch.
part of '../onboarding_screen.dart';

/// The wizard's inline message strip, shared by both layouts.
///
/// Occupies zero height when there is no notice, so the footer's position is
/// unchanged in the common case. When a notice is present it takes real space in
/// the Column above the footer, which is what guarantees the two can never
/// overlap.
///
/// Height is capped with an internal scroll so a long message (an exception
/// string from a failed save) shrinks the step body instead of squeezing the
/// Column into an overflow.
///
/// ONE banner per problem (05 §11): this is the only banner the wizard shell
/// draws, and the steps below it do not draw a second copy of the same
/// condition.
class _NoticeBand extends StatelessWidget {
  const _NoticeBand({required this.notice, required this.onDismiss});

  final _WizardNotice? notice;
  final VoidCallback onDismiss;

  static const double _maxHeight = 112;

  @override
  Widget build(BuildContext context) {
    final current = notice;
    if (current == null) return const SizedBox.shrink();
    return Padding(
      key: onboardingNoticeKey,
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _maxHeight),
        child: SingleChildScrollView(
          child: SkotiqBanner(
            title: current.message,
            tone: current.tone,
            onDismiss: onDismiss,
          ),
        ),
      ),
    );
  }
}

/// `STEP 3 OF 13` above the step panel (06 § Onboarding).
///
/// An eyebrow, not a headline: the progress is context for the panel beneath
/// it, and the wizard's one loud line is the step's own title inside that
/// panel.
class _ProgressEyebrow extends StatelessWidget {
  const _ProgressEyebrow({required this.currentStep, this.withLabel = false});

  final OnboardingStep currentStep;

  /// Appends the step's name. Used where there is no step rail to name it.
  final bool withLabel;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final count =
        'Step ${currentStep.order + 1} of ${OnboardingStepOrder.total}';
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      child: Text(
        withLabel ? '$count \u00b7 ${_StepRail.labelFor(currentStep)}' : count,
        style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// The wizard's page header action: leave setup for the dashboard.
///
/// Ghost, top right (06 § Onboarding). The wizard's single `primary` lives in
/// the footer on "Next".
class _SkipOnboardingAction extends StatelessWidget {
  const _SkipOnboardingAction({required this.onExit, this.compact = false});

  final VoidCallback? onExit;

  /// Glyph only. The label does not fit beside the title on a phone.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return SkotiqIconButton(
        icon: LucideIcons.logOut,
        tooltip: 'Skip onboarding',
        onPressed: onExit,
      );
    }
    return SkotiqButton(
      icon: LucideIcons.logOut,
      label: 'Skip onboarding',
      variant: ButtonVariant.ghost,
      size: ButtonSize.small,
      onPressed: onExit,
    );
  }
}

/// Phone progress track.
///
/// The phone column has no step rail, so the eyebrow's "Step 3 of 13" is the
/// only statement of progress; this 4 px track gives it a shape. Kept as a
/// [LinearProgressIndicator] because it is the wizard's existing progress
/// element, restyled onto `well`/`primary` — the design system's own
/// progress bar carries a label and a percentage the wizard does not want.
class _PhoneProgress extends StatelessWidget {
  const _PhoneProgress({required this.currentStep});

  final OnboardingStep currentStep;

  /// Track height. 4 px, the `spaceXs` step of the grid.
  static const double _trackHeight = SkotiqTokens.spaceXs;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final progress = (currentStep.order + 1) / OnboardingStepOrder.total;
    return ClipRRect(
      borderRadius: SkotiqTokens.borderRadiusFull,
      child: LinearProgressIndicator(
        value: progress,
        minHeight: _trackHeight,
        backgroundColor: colors.well,
        valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
      ),
    );
  }
}

/// Phone footer: primary action spans the full width on its own row (always
/// reachable, ≥48 px), with Back / Skip / "Capture first light" wrapped beneath
/// it so nothing overflows a narrow column.
class _PhoneFooter extends StatelessWidget {
  const _PhoneFooter({
    required this.currentStep,
    required this.isSaving,
    required this.onBack,
    required this.onSkipStep,
    required this.onNext,
    required this.onFirstLight,
    this.compact = false,
  });

  final OnboardingStep currentStep;
  final bool isSaving;
  final VoidCallback? onBack;
  final VoidCallback? onSkipStep;
  final VoidCallback? onNext;
  final VoidCallback? onFirstLight;

  /// Landscape-phone tier: lay the secondary actions BESIDE the primary in one
  /// row (the portrait layout stacks them beneath it) to reclaim vertical space
  /// on the ~410 px tall viewport.
  final bool compact;

  /// The phone primary action's tap surface. A touch-target floor, not a
  /// button size: the button inside it is `large` (40) and the row it sits in
  /// is 48.
  static const double _touchTargetHeight = SkotiqTokens.space4xl;

  @override
  Widget build(BuildContext context) {
    final actions = _FooterActions(currentStep);

    final secondary = <Widget>[
      if (onBack != null)
        SkotiqButton(
          icon: SkotiqIcons.arrowLeft,
          label: 'Back',
          variant: ButtonVariant.secondary,
          onPressed: onBack,
        ),
      if (onSkipStep != null)
        SkotiqButton(
          label: 'Skip this step',
          variant: ButtonVariant.ghost,
          onPressed: onSkipStep,
        ),
      if (actions.isNextSteps && onFirstLight != null)
        SkotiqButton(
          icon: SkotiqIcons.sparkle,
          label: 'Capture first light',
          variant: ButtonVariant.secondary,
          onPressed: isSaving ? null : onFirstLight,
        ),
    ];

    final primaryAction = SizedBox(
      key: phonePrimaryActionKey,
      height: _touchTargetHeight,
      child: SkotiqButton(
        icon: actions.primaryIcon,
        label: actions.primaryLabel,
        variant: ButtonVariant.primary,
        size: ButtonSize.large,
        isLoading: isSaving,
        onPressed: onNext,
      ),
    );

    // Landscape: one row — secondary actions on the left, primary on the right
    // (still ≥48 px tall). This trades the portrait two-row stack for a single
    // row so the short viewport keeps more height for the step body.
    if (compact) {
      return Row(
        children: [
          for (final action in secondary) ...[
            action,
            const SizedBox(width: SkotiqTokens.spaceSm),
          ],
          const Spacer(),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _compactPrimaryWidth),
            child: primaryAction,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: double.infinity, child: primaryAction),
        if (secondary.isNotEmpty) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: SkotiqTokens.spaceMd,
            runSpacing: SkotiqTokens.spaceSm,
            children: secondary,
          ),
        ],
      ],
    );
  }

  /// Minimum width of the primary action in the landscape row, so "Go to
  /// dashboard" keeps its label on one line beside the secondaries.
  static const double _compactPrimaryWidth = 160;
}

/// The step list beside the wizard body: 220 px, rail-style, one line per step.
///
/// Rail-style means the shell's expanded rail (04 §3.1): 40 px full-width
/// items, an 18 px glyph inset 11, a `button`-styled label, and a 12 %
/// `primary` wash on the current item. No panel wraps it — the list sits on
/// `background` exactly as the rail does, which is also what keeps the wizard
/// free of the full-height empty card that F5 records.
class _StepRail extends ConsumerWidget {
  const _StepRail({required this.currentStep, required this.draft});

  final OnboardingStep currentStep;

  /// The live draft, so a passed step is ticked only when it captured a value.
  final OnboardingDraft draft;

  /// Human-readable label for [step], shared with the page header.
  static String labelFor(OnboardingStep step) => _stepLabels[step] ?? '';

  /// The rail's width — the shell rail's expanded width (04 §3.1).
  static const double width = ShellChromeMetrics.railWidthExpanded;

  /// 03 §6 puts the rail glyph at 18; the icon scale has no 18 and the rail
  /// item's inset is derived from it, so it is named here as nav_item.dart
  /// names its own.
  static const double _glyphSize = 18.0;

  /// (40 − 18) / 2, the inset that centres the glyph in the item.
  static const double _glyphInset =
      (ShellChromeMetrics.railItemSize - _glyphSize) / 2;

  static const _stepLabels = <OnboardingStep, String>{
    OnboardingStep.welcome: 'Welcome',
    OnboardingStep.drivers: 'Drivers',
    OnboardingStep.camera: 'Camera',
    OnboardingStep.mount: 'Mount',
    OnboardingStep.focuser: 'Focuser',
    OnboardingStep.filterWheel: 'Filter wheel',
    OnboardingStep.guider: 'Guider',
    OnboardingStep.opticalTrain: 'Optical train',
    OnboardingStep.cameraDefaults: 'Camera defaults',
    OnboardingStep.captureDir: 'Capture folder',
    OnboardingStep.site: 'Observing site',
    OnboardingStep.summary: 'Review & save',
    OnboardingStep.nextSteps: "What's next",
  };

  static const _stepIcons = <OnboardingStep, IconData>{
    OnboardingStep.welcome: LucideIcons.heart,
    OnboardingStep.drivers: SkotiqIcons.connected,
    OnboardingStep.camera: SkotiqIcons.camera,
    OnboardingStep.mount: SkotiqIcons.compass,
    OnboardingStep.focuser: SkotiqIcons.focuser,
    OnboardingStep.filterWheel: SkotiqIcons.filterWheel,
    OnboardingStep.guider: SkotiqIcons.crosshair,
    OnboardingStep.opticalTrain: LucideIcons.ruler,
    OnboardingStep.cameraDefaults: SkotiqIcons.sliders,
    OnboardingStep.captureDir: SkotiqIcons.folder,
    OnboardingStep.site: LucideIcons.mapPin,
    OnboardingStep.summary: LucideIcons.clipboardCheck,
    OnboardingStep.nextSteps: LucideIcons.rocket,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final currentIdx = currentStep.order;

    // The observing site is a global observer setting, so it is the only step
    // whose value lives outside the draft. Null island (0,0) is the "not set"
    // sentinel, exactly as the Review screen reads it.
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final siteConfigured = settings != null && settings.hasObserverLocation;

    return SizedBox(
      width: width,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final step in OnboardingStep.values)
              _StepRailItem(
                label: _stepLabels[step] ?? '',
                icon: _stepIcons[step] ?? SkotiqIcons.circle,
                colors: colors,
                isActive: step == currentStep,
                // A tick claims the step configured something. Steps the user
                // walked past without supplying a value (a skipped focuser, a
                // guider whose test failed) get a dash instead — the same
                // answer the Review screen gives.
                isDone: step.order < currentIdx &&
                    draft.producedValueFor(step,
                        siteConfigured: siteConfigured),
                isSkipped: step.order < currentIdx &&
                    !draft.producedValueFor(step,
                        siteConfigured: siteConfigured),
              ),
          ],
        ),
      ),
    );
  }
}

/// One row of [_StepRail].
class _StepRailItem extends StatelessWidget {
  const _StepRailItem({
    required this.label,
    required this.icon,
    required this.colors,
    required this.isActive,
    required this.isDone,
    required this.isSkipped,
  });

  final String label;
  final IconData icon;
  final SkotiqColors colors;
  final bool isActive;
  final bool isDone;
  final bool isSkipped;

  @override
  Widget build(BuildContext context) {
    final IconData glyph;
    final Color glyphColor;
    final Color labelColor;
    final String state;
    if (isDone) {
      glyph = SkotiqIcons.check;
      glyphColor = colors.success;
      labelColor = colors.textSecondary;
      state = 'Configured';
    } else if (isSkipped) {
      glyph = SkotiqIcons.remove;
      glyphColor = colors.textMuted;
      labelColor = colors.textMuted;
      state = 'Skipped — nothing was set';
    } else if (isActive) {
      glyph = icon;
      glyphColor = colors.primary;
      labelColor = colors.primary;
      state = 'Current step';
    } else {
      glyph = icon;
      glyphColor = colors.textMuted;
      labelColor = colors.textSecondary;
      state = 'Not reached yet';
    }

    return Semantics(
      label: '$label. $state',
      selected: isActive,
      child: ExcludeSemantics(
        child: SkotiqTooltip(
          message: state,
          child: Container(
            height: ShellChromeMetrics.railItemSize,
            padding: const EdgeInsets.only(
              left: _StepRail._glyphInset,
              right: SkotiqTokens.spaceSm,
            ),
            decoration:
                isActive ? SkotiqDecorations.railItemSelected(colors) : null,
            child: Row(
              children: [
                Icon(glyph, size: _StepRail._glyphSize, color: glyphColor),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    label,
                    style: SkotiqTypography.button.copyWith(
                      color: labelColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepBody extends StatelessWidget {
  const _StepBody({required this.currentStep, required this.onFinishTo});

  final OnboardingStep currentStep;

  /// Routes a terminal next-step card to its destination after retiring the
  /// wizard. Forwarded from [_OnboardingScreenState._finishTo] so the in-body
  /// "what's next" cards and the footer share one finalize path.
  final ValueChanged<String> onFinishTo;

  @override
  Widget build(BuildContext context) {
    // Each step is its own widget. We keep this dispatch flat (rather
    // than a giant switch in the parent) so a step can own its
    // controllers and lifecycle without disturbing the wizard shell.
    switch (currentStep) {
      case OnboardingStep.welcome:
        return const OnboardingWelcomeStep();
      case OnboardingStep.drivers:
        return const OnboardingDriverStep();
      case OnboardingStep.camera:
        return const OnboardingCameraStep();
      case OnboardingStep.mount:
        return const OnboardingMountStep();
      case OnboardingStep.focuser:
        return const OnboardingFocuserStep();
      case OnboardingStep.filterWheel:
        return const OnboardingFilterWheelStep();
      case OnboardingStep.guider:
        return const OnboardingGuiderStep();
      case OnboardingStep.opticalTrain:
        return const OnboardingOpticalTrainStep();
      case OnboardingStep.cameraDefaults:
        return const OnboardingCameraDefaultsStep();
      case OnboardingStep.captureDir:
        return const OnboardingCaptureDirStep();
      case OnboardingStep.site:
        return const OnboardingSiteStep();
      case OnboardingStep.summary:
        return const OnboardingSummaryStep();
      case OnboardingStep.nextSteps:
        return OnboardingNextStepsStep(onNavigate: onFinishTo);
    }
  }
}

/// The three footer labels, derived once for both footers.
class _FooterActions {
  _FooterActions(OnboardingStep step)
      : isNextSteps = step == OnboardingStep.nextSteps,
        isSummary = step == OnboardingStep.summary;

  final bool isNextSteps;
  final bool isSummary;

  IconData get primaryIcon {
    if (isNextSteps) return LucideIcons.layoutDashboard;
    if (isSummary) return SkotiqIcons.check;
    return SkotiqIcons.arrowRight;
  }

  String get primaryLabel {
    if (isNextSteps) return 'Go to Tonight';
    if (isSummary) return 'Save profile';
    return 'Next';
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.currentStep,
    required this.isSaving,
    required this.onBack,
    required this.onSkipStep,
    required this.onNext,
    required this.onFirstLight,
  });

  final OnboardingStep currentStep;
  final bool isSaving;
  final VoidCallback? onBack;
  final VoidCallback? onSkipStep;
  final VoidCallback? onNext;

  /// Secondary "Capture first light" action, present only on the terminal
  /// `nextSteps` step. Null elsewhere.
  final VoidCallback? onFirstLight;

  @override
  Widget build(BuildContext context) {
    final actions = _FooterActions(currentStep);

    return Row(
      children: [
        // On step 1 of 13 `onBack` is null. Drawing the button anyway
        // publishes a plain `button: Back` with no disabled state that does
        // nothing when clicked, and the phone footer above omits it, so the two
        // footers would disagree. A control that cannot act must not be on
        // screen claiming it can.
        if (onBack != null)
          SkotiqButton(
            icon: SkotiqIcons.arrowLeft,
            label: 'Back',
            variant: ButtonVariant.secondary,
            onPressed: onBack,
          ),
        const Spacer(),
        if (onSkipStep != null) ...[
          SkotiqButton(
            label: 'Skip this step',
            variant: ButtonVariant.ghost,
            onPressed: onSkipStep,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
        ],
        if (actions.isNextSteps && onFirstLight != null) ...[
          SkotiqButton(
            icon: SkotiqIcons.sparkle,
            label: 'Capture first light',
            variant: ButtonVariant.secondary,
            onPressed: isSaving ? null : onFirstLight,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
        ],
        SkotiqButton(
          icon: actions.primaryIcon,
          label: actions.primaryLabel,
          variant: ButtonVariant.primary,
          isLoading: isSaving,
          onPressed: onNext,
        ),
      ],
    );
  }
}

/// The wizard's header as window chrome on a desktop window.
///
/// The wizard is routed outside the AppShell, so on a frameless desktop window
/// its header is the only place to drag, maximize or close the window from.
class _WizardWindowChrome extends StatelessWidget {
  const _WizardWindowChrome({required this.child});

  final Widget child;

  /// macOS keeps its native traffic lights; every other desktop window needs
  /// the app's own caption buttons.
  static bool get showsWindowControls =>
      ShellChrome.isDesktopWindow && !kIsWebLike && !Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    if (!ShellChrome.isDesktopWindow) return child;
    return WindowDragArea(child: child);
  }
}
