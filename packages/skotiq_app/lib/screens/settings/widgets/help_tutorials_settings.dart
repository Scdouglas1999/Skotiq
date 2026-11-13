import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/first_light/first_light_flow_dialog.dart';
import 'settings_widgets.dart';
import '../../../router/app_routes.dart';
import '../../../tours/tour.dart';
import '../../../tours/tour_runner.dart';

class HelpTutorialsSettings extends ConsumerWidget {
  const HelpTutorialsSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final run = ref.watch(tourRunnerProvider);
    final runner = ref.read(tourRunnerProvider.notifier);
    // A tour left part-way resumes where it stopped; anything else starts.
    String startOrResume(Tour tour) {
      final done = run.stepsDone(tour);
      return done > 0 && !run.isCompleted(tour) ? 'Resume' : 'Start';
    }

    return SettingsPage(
      key: TourTarget.settingsHelp.key,
      title: 'Help & tutorials',
      description: 'Guided tours and learning resources',
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
          children: [
            SettingRow(
              icon: LucideIcons.sparkles,
              iconColor: colors.primary,
              title: 'First night walkthrough',
              subtitle: '7-step guided wizard for your first imaging session — '
                  'connect, polar align, focus, frame, guide, sequence.',
              trailing: _AsyncActionButton(
                label: startOrResume(Tour.firstNight),
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                icon: LucideIcons.play,
                failureMessage:
                    'Could not open the walkthrough. Please try again.',
                onPressed: () => runner.resume(Tour.firstNight),
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
                  context.go(AppRoute.onboarding.path);
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
                label: startOrResume(Tour.firstLaunch),
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                icon: LucideIcons.play,
                failureMessage:
                    'Could not open the onboarding tour. Please try again.',
                onPressed: () => runner.resume(Tour.firstLaunch),
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
                onPressed: () => context.push(AppRoute.diagnosticsDump.path),
              ),
              isLast: true,
            ),
          ],
        ),
        SettingsSection(
          title: 'Tutorial tours',
          children: [
            for (final tour in Tour.workflows)
              _TutorialRow(
                icon: tour.icon!,
                title: tour.title,
                completedSteps: run.stepsDone(tour),
                totalSteps: tour.steps.length,
                isCompleted: run.isCompleted(tour),
                onStart: () => runner.start(tour),
                onResume: () => runner.resume(tour),
                isLast: tour == Tour.workflows.last,
              ),
          ],
        ),
        SettingsSection(
          title: 'Reset progress',
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
              // The sentence above promises the welcome tour, so it starts.
              onPressed: () async {
                final runner = ref.read(tourRunnerProvider.notifier);
                await runner.resetAll();
                await runner.start(Tour.firstLaunch);
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
  final int completedSteps;
  final int totalSteps;
  final bool isCompleted;

  /// Shows the tour from its first step.
  final FutureOr<void> Function() onStart;

  /// Shows the tour where it was left.
  final FutureOr<void> Function() onResume;
  final bool isLast;

  bool get hasProgress => completedSteps > 0;

  const _TutorialRow({
    required this.icon,
    required this.title,
    required this.completedSteps,
    required this.totalSteps,
    required this.isCompleted,
    required this.onStart,
    required this.onResume,
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
    return widget.hasProgress && !widget.isCompleted
        ? widget.onResume
        : widget.onStart;
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
