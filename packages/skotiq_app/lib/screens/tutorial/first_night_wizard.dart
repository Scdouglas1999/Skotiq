import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        FirstNightWizardStep,
        FirstNightWizardState,
        firstNightWizardProvider,
        FirstNightWizardNotifier,
        guidedFlowActiveProvider,
        // Alias for the model-layer `FirstNightWizard` (hidden from the
        // barrel because it collides with this widget class of the same
        // name). Defined in `src/legacy_aliases.dart`.
        FirstNightWizardModel;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';
import 'tutorial_step_widget.dart';

/// First-night wizard — a 7-step modal walkthrough for new users.
///
/// Replay-only: reached solely from Settings → Help & Tutorials, the single
/// replay hub for walkthroughs. The startup spine is the equipment-onboarding
/// wizard gated by `EquipmentOnboardingLauncher` in `app.dart` — do not wire
/// this wizard into bootstrap.
///
/// The wizard's progress is persisted to `tutorial_progress` so closing the
/// dialog mid-way and re-opening it from Settings resumes at the same step.
///
/// Why a ConsumerStatefulWidget instead of a stateless dialog: the
/// wizard waits for the saved-progress load before painting any step, so
/// a freshly-launched app doesn't flash step 0 before jumping to the
/// resumed step. That requires watching the provider through riverpod.
class FirstNightWizard extends ConsumerStatefulWidget {
  const FirstNightWizard({super.key});

  /// Show the wizard as a modal dialog over the current navigator. Returns
  /// when the user closes the dialog (either via Done, Skip Forever, or
  /// the close button). Callers don't need to handle the return value —
  /// all persistence happens inside the notifier.
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const FirstNightWizard(),
    );
  }

  @override
  ConsumerState<FirstNightWizard> createState() => _FirstNightWizardState();
}

class _FirstNightWizardState extends ConsumerState<FirstNightWizard> {
  // Cache the steps once per dialog open. The core getter validates the
  // seven-step length invariant on every read; doing it once per dialog
  // is sufficient and avoids re-running that check on every rebuild.
  late final List<FirstNightWizardStep> _steps = FirstNightWizardModel.steps;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    // Claim the user's attention for this walkthrough so the per-screen
    // "New to this screen?" nudges stand down. Released explicitly in Done /
    // Skip forever / Close — NOT in dispose, because "Show me on the X screen"
    // pops this dialog to park the walkthrough on that screen, and a nudge
    // offering a tour of the screen the walkthrough just sent you to is the
    // second guided flow this flag exists to prevent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(guidedFlowActiveProvider.notifier).state = true;
    });
  }

  /// Hand the screen back to the ordinary per-screen tour offers.
  void _releaseGuidedFlow() {
    ref.read(guidedFlowActiveProvider.notifier).state = false;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(firstNightWizardProvider);
    final notifier = ref.read(firstNightWizardProvider.notifier);
    final l10n = context.l10n;

    // Until the saved index has loaded from the DAO, show a small spinner
    // dialog. We intentionally do NOT render step 0 here — that would
    // flash the welcome step for a frame before jumping to (say) step 5
    // for a returning resumer.
    if (!state.isLoaded) {
      return SkotiqDialog(
        title: l10n.text('firstNightWizardTitle'),
        icon: SkotiqIcons.sparkle,
        width: 600,
        height: 400,
        showCloseButton: false,
        child: const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
        ),
      );
    }

    final currentStep = _steps[state.currentStepIndex];

    return SkotiqDialog(
      title: l10n.text('firstNightWizardTitle'),
      icon: SkotiqIcons.sparkle,
      width: 640,
      height: 560,
      closeEnabled: !_isSaving,
      // Closing just dismisses the dialog. Progress is persisted as the user
      // steps through, so re-opening from Settings → Help resumes at the same
      // step. The wizard is replay-only, so closing here makes no promise about
      // a next-launch reopen.
      onClose: () {
        _releaseGuidedFlow();
        Navigator.of(context).pop();
      },
      actions: _buildActions(context, state, notifier),
      child: TutorialStepWidget(
        step: currentStep,
        currentIndex: state.currentStepIndex,
        totalSteps: _steps.length,
        onShowMe: _isSaving
            ? null
            : () => _handleShowMe(context, currentStep, notifier),
      ),
    );
  }

  /// Build the footer button row. Layout shifts by step position:
  /// - First step: [Skip Forever] [Close] [Next]
  /// - Middle steps: [Skip Forever] [Back] [Next]
  /// - Last step: [Skip Forever] [Back] [Done]
  /// The Skip Forever ghost button is always visible so the user can opt
  /// out at any time; we don't trap them in the wizard.
  List<Widget> _buildActions(
    BuildContext context,
    FirstNightWizardState state,
    FirstNightWizardNotifier notifier,
  ) {
    final l10n = context.l10n;
    return [
      SkotiqButton(
        label: l10n.text('firstNightWizardSkipForever'),
        variant: ButtonVariant.ghost,
        size: ButtonSize.small,
        onPressed:
            _isSaving ? null : () => _handleSkipForever(context, notifier),
      ),
      const SizedBox(width: 8),
      if (notifier.isFirstStep)
        SkotiqButton(
          label: l10n.text('commonClose'),
          variant: ButtonVariant.outline,
          size: ButtonSize.small,
          onPressed: _isSaving
              ? null
              : () {
                  _releaseGuidedFlow();
                  Navigator.of(context).pop();
                },
        )
      else
        SkotiqButton(
          label: l10n.text('commonBack'),
          icon: SkotiqIcons.chevronLeft,
          variant: ButtonVariant.outline,
          size: ButtonSize.small,
          onPressed: _isSaving ? null : () => _run(notifier.back),
        ),
      const SizedBox(width: 8),
      if (notifier.isLastStep)
        SkotiqButton(
          label: l10n.text('commonDone'),
          icon: SkotiqIcons.check,
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
          isLoading: _isSaving,
          onPressed: _isSaving ? null : () => _handleDone(context, notifier),
        )
      else
        SkotiqButton(
          label: l10n.text('commonNext'),
          icon: SkotiqIcons.chevronRight,
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
          isLoading: _isSaving,
          onPressed: _isSaving ? null : () => _run(notifier.next),
        ),
    ];
  }

  /// "Show me" deep-link handler. Saves progress (so we resume here when
  /// the wizard is reopened), closes the wizard, then navigates. We
  /// intentionally don't leave the wizard open behind the screen — modal
  /// dialogs over deep-content screens get visually confusing fast.
  Future<void> _handleShowMe(
    BuildContext context,
    FirstNightWizardStep step,
    FirstNightWizardNotifier notifier,
  ) async {
    if (!step.hasDeepLink) return;
    await _run(() => notifier.goToStep(step.order), onSuccess: () {
      Navigator.of(context).pop();
      // Use post-frame to let the dialog pop animation finish before the
      // route change — otherwise the navigator collapse and the go_router
      // push race and the new screen appears half-transitioned.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          context.go(step.deepLinkRoute);
        }
      });
    });
  }

  Future<void> _handleSkipForever(
    BuildContext context,
    FirstNightWizardNotifier notifier,
  ) async {
    await _run(notifier.dismissForever, onSuccess: () {
      _releaseGuidedFlow();
      Navigator.of(context).pop();
    });
  }

  Future<void> _handleDone(
    BuildContext context,
    FirstNightWizardNotifier notifier,
  ) async {
    await _run(notifier.complete, onSuccess: () {
      _releaseGuidedFlow();
      Navigator.of(context).pop();
    });
  }

  Future<void> _run(
    Future<void> Function() operation, {
    VoidCallback? onSuccess,
  }) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await operation();
      if (!mounted) return;
      onSuccess?.call();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Could not save tutorial progress. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
