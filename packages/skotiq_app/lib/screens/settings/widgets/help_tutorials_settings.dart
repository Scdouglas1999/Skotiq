import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/tutorial_keys/settings_keys.dart';
import '../../../widgets/first_light/first_light_flow_dialog.dart';
import 'settings_widgets.dart';

class HelpTutorialsSettings extends ConsumerWidget {
  final bool isMobile;

  const HelpTutorialsSettings({super.key, this.isMobile = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final tutorialState = ref.watch(tutorialProvider);
    final notifier = ref.read(tutorialProvider.notifier);

    return SettingsPage(
      key: SettingsTutorialKeys.help,
      title: 'Help & tutorials',
      description: 'Guided tours and learning resources',
      isMobile: isMobile,
      hideHeader: isMobile,
      children: [
        // The single replay hub for the guided first-run flows: each
        // auto-launches at most once on the startup spine and is replayable
        // here on demand.
        //
        // Every row here does the same kind of thing — start a flow — so they
        // all wear ONE verb and ONE button treatment; a filled primary among
        // outlines reads as if the rows differed in kind. Row titles are
        // sentence case, the register the rest of Settings uses; section
        // HEADERS stay Title Case, as they are app-wide. The titles are
        // mirrored into settings_search_index.g.dart, regenerated with
        // `dart run tools/production/settings_search_index_gen.dart`.
        SettingsSection(
          title: 'Guided flows',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.sparkles,
              iconColor: colors.primary,
              title: 'First night walkthrough',
              subtitle: '7-step guided wizard for your first imaging session — '
                  'connect, polar align, focus, frame, guide, sequence.',
              trailing: _AsyncActionButton(
                label: 'Start',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                icon: LucideIcons.play,
                failureMessage:
                    'Could not restart the walkthrough. Please try again.',
                // Re-open the wizard via its dedicated route. We restart
                // the in-memory step index first so a user who clicks
                // "Start" gets the welcome step, not their resumed
                // mid-tutorial position — the explicit Start action means
                // "show me from the beginning". (Resume is the auto-open
                // behavior, not what they asked for here.)
                onPressed: () async {
                  await ref.read(firstNightWizardProvider.notifier).restart();
                  if (context.mounted) context.go('/tutorial/first-night');
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.aperture,
              iconColor: colors.primary,
              title: 'Capture your first light',
              subtitle:
                  'Run the one-click first-light flow again — short exposure, '
                  'auto-stretch, plate-solve, and label the field. Make sure a '
                  'camera is connected first.',
              trailing: SkotiqButton(
                label: 'Start',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                icon: LucideIcons.play,
                // The first-light flow is camera-driven and self-contained:
                // FirstLightFlowDialog opens over the current screen,
                // resetting its controller on dismissal so a replay starts
                // from a clean intro panel. No route change needed.
                onPressed: () => FirstLightFlowDialog.show(context),
              ),
            ),
            SettingRow(
              icon: LucideIcons.wrench,
              iconColor: colors.primary,
              title: 'Re-run equipment setup',
              subtitle:
                  'Walk back through the equipment onboarding wizard to scan '
                  'for gear, pick devices, and rebuild a profile from scratch.',
              trailing: _AsyncActionButton(
                label: 'Start',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                icon: LucideIcons.play,
                failureMessage:
                    'Could not reset equipment setup. Please try again.',
                // Clear the in-progress draft so the spine starts on the
                // welcome step rather than resuming a stale half-finished
                // draft, then route to the onboarding spine. The gate
                // provider (shouldRunEquipmentOnboardingProvider) is not
                // touched — re-running setup with profiles already present
                // is an explicit user action, not an auto-launch, so the
                // gate stays satisfied and won't auto-fire on next launch.
                onPressed: () async {
                  await ref.read(onboardingDraftProvider.notifier).reset();
                  if (!context.mounted) return;
                  context.go('/onboarding');
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.compass,
              iconColor: colors.primary,
              title: 'Re-run onboarding tour',
              subtitle:
                  'Replay the first-launch spotlight tour that highlights '
                  'where Equipment, Sequencer, Scheduler, and Plate Solving '
                  'live in the app.',
              trailing: _AsyncActionButton(
                label: 'Start',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                icon: LucideIcons.play,
                failureMessage:
                    'Could not restart the onboarding tour. Please try again.',
                // Reset the DAO row + in-memory pointer. The first-launch tour
                // overlay is replay-only, off the startup spine: resetting
                // flips firstLaunchTourStatusProvider back to pending, and
                // OnboardingTourReplayLauncher (mounted at the app-shell level)
                // watches that provider and re-mounts the overlay immediately —
                // no restart needed.
                onPressed: () async {
                  await ref.read(onboardingTourProvider.notifier).reset();
                },
              ),
              isLast: false,
            ),
            SettingRow(
              icon: LucideIcons.archive,
              iconColor: colors.warning,
              title: 'Generate diagnostic dump',
              subtitle:
                  'Package logs, settings, profile metadata, and system details for support.',
              trailing: SkotiqButton(
                label: 'Start',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                icon: LucideIcons.play,
                onPressed: () => context.push('/diagnostics/dump'),
              ),
              isLast: true,
            ),
          ],
        ),
        SettingsSection(
          title: 'Tutorial tours',
          isMobile: isMobile,
          children: [
            // The "Quick Start Tour" (TutorialCategory.firstLight step tour)
            // was removed here: it is superseded by the real, camera-driven
            // first-light flow surfaced as "Capture your first light" in the
            // Guided Flows section above. Keeping both would offer two
            // different things under near-identical names.
            _TutorialRow(
              icon: LucideIcons.boxes,
              title: 'Equipment setup',
              category: TutorialCategory.equipmentSetup,
              completedSteps: notifier
                  .getCompletedStepsCount(TutorialCategory.equipmentSetup),
              totalSteps:
                  notifier.getTotalStepsCount(TutorialCategory.equipmentSetup),
              isCompleted: notifier
                  .isCategoryCompletedSync(TutorialCategory.equipmentSetup),
              hasProgress:
                  notifier.hasCategoryProgress(TutorialCategory.equipmentSetup),
              onStart: () =>
                  notifier.restartTutorial(TutorialCategory.equipmentSetup),
              onResume: () =>
                  notifier.resumeTutorial(TutorialCategory.equipmentSetup),
              onRestart: () =>
                  notifier.restartTutorial(TutorialCategory.equipmentSetup),
            ),
            _TutorialRow(
              icon: LucideIcons.compass,
              title: 'Target planning',
              category: TutorialCategory.targetPlanning,
              completedSteps: notifier
                  .getCompletedStepsCount(TutorialCategory.targetPlanning),
              totalSteps:
                  notifier.getTotalStepsCount(TutorialCategory.targetPlanning),
              isCompleted: notifier
                  .isCategoryCompletedSync(TutorialCategory.targetPlanning),
              hasProgress:
                  notifier.hasCategoryProgress(TutorialCategory.targetPlanning),
              onStart: () =>
                  notifier.restartTutorial(TutorialCategory.targetPlanning),
              onResume: () =>
                  notifier.resumeTutorial(TutorialCategory.targetPlanning),
              onRestart: () =>
                  notifier.restartTutorial(TutorialCategory.targetPlanning),
            ),
            _TutorialRow(
              icon: LucideIcons.listOrdered,
              title: 'Automated imaging',
              category: TutorialCategory.automatedImaging,
              completedSteps: notifier
                  .getCompletedStepsCount(TutorialCategory.automatedImaging),
              totalSteps: notifier
                  .getTotalStepsCount(TutorialCategory.automatedImaging),
              isCompleted: notifier
                  .isCategoryCompletedSync(TutorialCategory.automatedImaging),
              hasProgress: notifier
                  .hasCategoryProgress(TutorialCategory.automatedImaging),
              onStart: () =>
                  notifier.restartTutorial(TutorialCategory.automatedImaging),
              onResume: () =>
                  notifier.resumeTutorial(TutorialCategory.automatedImaging),
              onRestart: () =>
                  notifier.restartTutorial(TutorialCategory.automatedImaging),
            ),
            _TutorialRow(
              icon: LucideIcons.sun,
              title: 'Calibration frames',
              category: TutorialCategory.calibrationFrames,
              completedSteps: notifier
                  .getCompletedStepsCount(TutorialCategory.calibrationFrames),
              totalSteps: notifier
                  .getTotalStepsCount(TutorialCategory.calibrationFrames),
              isCompleted: notifier
                  .isCategoryCompletedSync(TutorialCategory.calibrationFrames),
              hasProgress: notifier
                  .hasCategoryProgress(TutorialCategory.calibrationFrames),
              onStart: () =>
                  notifier.restartTutorial(TutorialCategory.calibrationFrames),
              onResume: () =>
                  notifier.resumeTutorial(TutorialCategory.calibrationFrames),
              onRestart: () =>
                  notifier.restartTutorial(TutorialCategory.calibrationFrames),
            ),
            _TutorialRow(
              icon: LucideIcons.barChart3,
              title: 'Advanced features',
              category: TutorialCategory.advancedFeatures,
              completedSteps: notifier
                  .getCompletedStepsCount(TutorialCategory.advancedFeatures),
              totalSteps: notifier
                  .getTotalStepsCount(TutorialCategory.advancedFeatures),
              isCompleted: notifier
                  .isCategoryCompletedSync(TutorialCategory.advancedFeatures),
              hasProgress: notifier
                  .hasCategoryProgress(TutorialCategory.advancedFeatures),
              onStart: () =>
                  notifier.restartTutorial(TutorialCategory.advancedFeatures),
              onResume: () =>
                  notifier.resumeTutorial(TutorialCategory.advancedFeatures),
              onRestart: () =>
                  notifier.restartTutorial(TutorialCategory.advancedFeatures),
              isLast: true,
            ),
          ],
        ),
        SettingsSection(
          title: 'Reset progress',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.refreshCw,
              iconColor: colors.error,
              title: 'Reset all progress',
              subtitle: 'Clear all tutorial progress and start fresh',
              trailing: SkotiqButton(
                label: 'Reset',
                variant: ButtonVariant.destructive,
                size: ButtonSize.small,
                onPressed: () => _showResetConfirmation(context, ref),
              ),
              isLast: true,
            ),
          ],
        ),
        SettingsSection(
          title: 'Settings',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.toggleRight,
              title: 'Enable tutorials',
              subtitle: 'Show tutorial prompts and guided tours',
              trailing: SettingsSwitch(
                value: tutorialState.tutorialsEnabled,
                onChanged: (value) {
                  return notifier.setTutorialsEnabled(value);
                },
              ),
              isLast: true,
            ),
          ],
        ),
      ],
    );
  }

  void _showResetConfirmation(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) {
        final colors = SkotiqColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            side: BorderSide(color: colors.border),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: SkotiqDecorations.chip(colors, tone: colors.error),
                child: Icon(LucideIcons.alertTriangle,
                    color: colors.error, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                'Reset Tutorial Progress?',
                style: SkotiqTypography.sectionTitle
                    .copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          content: Text(
            'This will clear all tutorial progress and you will see the welcome tour again. This action cannot be undone.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.pop(ctx),
            ),
            _AsyncActionButton(
              label: 'Reset',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              failureMessage:
                  'Could not reset tutorial progress. Please try again.',
              // Do the whole of what the sentence above promises.
              //
              // `resetProgress` deletes every tutorial_progress row — including
              // the ones that record a dismissed coach mark — but nothing told
              // the live app about it: the dismissed-prompt set is held in
              // memory and the first-launch tour's status is a cached future.
              // So "you will see the welcome tour again" produced no tour and
              // no nudge for the rest of the session. Drop the in-memory
              // dismissals and re-arm the welcome tour through the same path
              // the "Re-run onboarding tour" row above uses.
              onPressed: () async {
                await ref.read(tutorialProvider.notifier).resetProgress();
                await ref
                    .read(dismissedTourPromptsProvider.notifier)
                    .resetAllDismissed();
                await ref.read(onboardingTourProvider.notifier).reset();
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
          ],
        );
      },
    );
  }
}

class _TutorialRow extends StatefulWidget {
  final IconData icon;
  final String title;
  final TutorialCategory category;
  final int completedSteps;
  final int totalSteps;
  final bool isCompleted;
  final bool hasProgress;
  final FutureOr<void> Function() onStart;
  final FutureOr<void> Function() onResume;
  final FutureOr<void> Function() onRestart;
  final bool isLast;

  const _TutorialRow({
    required this.icon,
    required this.title,
    required this.category,
    required this.completedSteps,
    required this.totalSteps,
    required this.isCompleted,
    required this.hasProgress,
    required this.onStart,
    required this.onResume,
    required this.onRestart,
    this.isLast = false,
  });

  @override
  State<_TutorialRow> createState() => _TutorialRowState();
}

class _TutorialRowState extends State<_TutorialRow> {
  bool _isRunning = false;

  String get _statusText {
    if (widget.isCompleted) {
      return 'Completed';
    } else if (widget.hasProgress) {
      return '${widget.completedSteps}/${widget.totalSteps} steps';
    } else {
      return 'Not started';
    }
  }

  String get _buttonText {
    if (widget.isCompleted) {
      return 'Restart';
    } else if (widget.hasProgress) {
      return 'Resume';
    } else {
      return 'Start';
    }
  }

  FutureOr<void> Function() get _buttonAction {
    if (widget.isCompleted) {
      return widget.onRestart;
    } else if (widget.hasProgress) {
      return widget.onResume;
    } else {
      return widget.onStart;
    }
  }

  Future<void> _runAction() async {
    if (_isRunning) return;
    setState(() => _isRunning = true);
    try {
      await Future<void>.sync(_buttonAction);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Could not ${_buttonText.toLowerCase()} '
              '${widget.title}. Please try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Semantics(
      // Semantics publishes isEnabled only when this field is given;
      // omitting it makes assistive tech announce a live control as
      // disabled. Measured on the running app 2026-08-09.
      enabled: true,
      label: '${widget.title} tutorial, $_statusText',
      button: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: widget.isLast
              ? null
              : Border(
                  bottom:
                      BorderSide(color: colors.border.withValues(alpha: 0.5)),
                ),
        ),
        child: Row(
          children: [
            // Icon
            Container(
              width: 36,
              height: 36,
              decoration: widget.isCompleted
                  ? SkotiqDecorations.chip(colors, tone: colors.success)
                  : BoxDecoration(
                      color: colors.well,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline8),
                    ),
              child: Icon(
                widget.icon,
                size: 16,
                color:
                    widget.isCompleted ? colors.success : colors.textSecondary,
              ),
            ),
            const SizedBox(width: 14),

            // Title and status
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: SkotiqTypography.label
                        .copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (widget.isCompleted)
                        Icon(
                          LucideIcons.checkCircle2,
                          size: 12,
                          color: colors.success,
                        )
                      else if (widget.hasProgress)
                        Icon(
                          LucideIcons.clock,
                          size: 12,
                          color: colors.warning,
                        )
                      else
                        Icon(
                          LucideIcons.circle,
                          size: 12,
                          color: colors.textMuted,
                        ),
                      const SizedBox(width: 4),
                      Text(
                        _statusText,
                        style: SkotiqTypography.captionSm.copyWith(
                          color: widget.isCompleted
                              ? colors.success
                              : widget.hasProgress
                                  ? colors.warning
                                  : colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Action button
            SkotiqButton(
              label: _buttonText,
              // A page of equal-weight replay rows has no primary among them:
              // the completion state is already published by the icon, the
              // status line and the verb itself.
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              isLoading: _isRunning,
              onPressed: _isRunning ? null : _runAction,
            ),
          ],
        ),
      ),
    );
  }
}

class _AsyncActionButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final ButtonVariant variant;
  final ButtonSize size;
  final FutureOr<void> Function() onPressed;
  final String failureMessage;

  const _AsyncActionButton({
    required this.label,
    this.icon,
    required this.variant,
    required this.size,
    required this.onPressed,
    required this.failureMessage,
  });

  @override
  State<_AsyncActionButton> createState() => _AsyncActionButtonState();
}

class _AsyncActionButtonState extends State<_AsyncActionButton> {
  bool _isRunning = false;

  Future<void> _run() async {
    if (_isRunning) return;
    setState(() => _isRunning = true);
    try {
      await Future<void>.sync(widget.onPressed);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(widget.failureMessage)),
        );
      }
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqButton(
      label: widget.label,
      icon: widget.icon,
      variant: widget.variant,
      size: widget.size,
      isLoading: _isRunning,
      onPressed: _isRunning ? null : _run,
    );
  }
}
