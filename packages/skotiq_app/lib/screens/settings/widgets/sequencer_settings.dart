import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../widgets/help/field_help_copy.dart';
import 'safety_fail_mode_labels.dart';
import 'settings_widgets.dart';

class SequencerSettings extends ConsumerStatefulWidget {
  const SequencerSettings({super.key});

  @override
  ConsumerState<SequencerSettings> createState() => _SequencerSettingsState();
}

class _SequencerSettingsState extends ConsumerState<SequencerSettings> {
  Widget _buildBroadcastSection(SequencerDefaults defaults, Object authority) {
    final notifier = ref.read(sequencerDefaultsProvider.notifier);
    return SettingsSection(
      title: 'Live stacking & broadcast',
      children: [
        SettingRow(
          icon: LucideIcons.shieldOff,
          title: 'Disable broadcast everywhere',
          subtitle: 'Master kill switch — every LiveStacking node will '
              'build the stack in memory but refuse public requests. '
              'Useful when you want to test without exposing imagery.',
          trailing: SettingsSwitch(
            value: defaults.livestackingDisableEverywhere,
            onChanged: (value) {
              return notifier.updateLiveStackingDefaults(
                disableEverywhere: value,
              );
            },
          ),
        ),
        SettingRow(
          icon: LucideIcons.layers,
          title: 'Default stack method',
          subtitle: 'Average is fastest; Median + Rejection and Sigma '
              'reject outliers but are slower.',
          trailing: settingsTrailingChoice<LiveStackingMethod>(
            value: defaults.livestackingDefaultStackMethod,
            values: LiveStackingMethod.values,
            labelOf: (method) => method.label,
            designWidth: 200,
            onChanged: (method) => notifier.updateLiveStackingDefaults(
              defaultStackMethod: method,
            ),
          ),
        ),
        SettingRow(
          icon: LucideIcons.type,
          title: 'Default watermark template',
          subtitle: 'Rendered on the broadcast JPEG. Variable interpolation '
              r'(e.g. "${target.name} — L ${integration.hms}") applied at '
              'render time. Leave empty for no watermark.',
          trailing: settingsTrailingTextInput(
            context: context,
            authoritativeValue: defaults.livestackingDefaultWatermark ?? '',
            authorityKey: authority,
            hint: 'e.g. M42 — \${integration.hms}',
            designWidth: 240,
            onChanged: (value) {
              // Persist empty string as cleared (null in memory). The
              // notifier's _sentinel pattern preserves the distinction
              // so reload sees an empty default rather than the
              // hard-coded fallback.
              return notifier.updateLiveStackingDefaults(
                defaultWatermark: value.isEmpty ? null : value,
              );
            },
          ),
        ),
        SettingRow(
          icon: LucideIcons.globe2,
          title: 'Public by default',
          subtitle: 'Off → new nodes start with auth required. Turn on '
              'only if you routinely run public outreach events.',
          trailing: SettingsSwitch(
            value: defaults.livestackingPublicByDefault,
            onChanged: (value) {
              return notifier.updateLiveStackingDefaults(
                publicByDefault: value,
              );
            },
          ),
        ),
        SettingRow(
          icon: LucideIcons.image,
          title: 'Default thumbnail size',
          subtitle: 'Output dimensions for the broadcast JPEG. Smaller '
              'is phone-friendly; larger preserves more detail.',
          trailing: settingsTrailingChoice<LiveStackingThumbnailSize>(
            value: defaults.livestackingDefaultThumbnailSize,
            values: LiveStackingThumbnailSize.values,
            labelOf: (size) => size.label,
            designWidth: 220,
            onChanged: (size) => notifier.updateLiveStackingDefaults(
              defaultThumbnailSize: size,
            ),
          ),
          isLast: true,
        ),
      ],
    );
  }

  Widget _buildMeridianFlipSection(
    MeridianFlipSettings flipSettings,
    Object authority,
  ) {
    final notifier = ref.read(globalMeridianFlipSettingsProvider.notifier);
    final standaloneSupported =
        flipSettings.triggerMethod.supportsStandaloneMonitoring;

    return SettingsSection(
      title: 'Meridian flip',
      children: [
        // Standalone monitoring
        SettingRow(
          icon: LucideIcons.eye,
          title: 'Standalone monitoring',
          subtitle: standaloneSupported
              ? 'Monitor meridian even when no sequence is running'
              : '${flipSettings.triggerMethod.standaloneMonitoringLimitation} '
                  'Standalone monitoring is unavailable for this trigger.',
          trailing: SettingsSwitch(
            value:
                flipSettings.standaloneMonitoringEnabled && standaloneSupported,
            enabled: standaloneSupported,
            onChanged: (value) {
              return notifier.setStandaloneMonitoringEnabled(value);
            },
          ),
        ),
        // Trigger method
        SettingRow(
          icon: LucideIcons.crosshair,
          title: 'Trigger method',
          subtitle: flipSettings.triggerMethod.description,
          trailing: settingsTrailingChoice<MeridianTriggerMethod>(
            value: flipSettings.triggerMethod,
            values: MeridianTriggerMethod.values,
            labelOf: (method) => method.displayName,
            designWidth: 200,
            onChanged: notifier.setTriggerMethod,
          ),
        ),
        // Trigger value - minutes past meridian
        if (flipSettings.triggerMethod ==
            MeridianTriggerMethod.minutesPastMeridian)
          SettingRow(
            icon: LucideIcons.timer,
            title: 'Minutes past meridian',
            helpId: FieldHelpId.meridianFlipTrigger,
            subtitle: 'Flip after target crosses meridian by this amount',
            trailing: SettingsNumberInput(
              authoritativeValue: flipSettings.minutesPastMeridian,
              authorityKey: authority,
              suffix: 'min',
              min: 0,
              max: 120,
              decimals: 1,
              onChanged: (value) {
                return notifier.setMinutesPastMeridian(value);
              },
            ),
          ),
        if (flipSettings.triggerMethod ==
            MeridianTriggerMethod.minutesPastMeridian)
          SettingRow(
            icon: LucideIcons.pause,
            title: 'Stop tracking before meridian',
            subtitle: '0 = off. Tracking stops this many minutes before the '
                'meridian and the flip runs at Minutes Past Meridian.',
            trailing: SettingsNumberInput(
              authoritativeValue: flipSettings.pauseBeforeMeridianMinutes,
              authorityKey: authority,
              suffix: 'min',
              min: 0,
              max: 120,
              decimals: 1,
              onChanged: (value) {
                return notifier.setPauseBeforeMeridianMinutes(value);
              },
            ),
          ),
        // Trigger value - minutes before limit
        if (flipSettings.triggerMethod ==
            MeridianTriggerMethod.minutesBeforeLimit)
          SettingRow(
            icon: LucideIcons.timer,
            title: 'Minutes before limit',
            subtitle: 'Flip before mount reaches tracking limit',
            trailing: SettingsNumberInput(
              authoritativeValue: flipSettings.minutesBeforeLimit,
              authorityKey: authority,
              suffix: 'min',
              min: 0,
              max: 120,
              decimals: 1,
              onChanged: (value) {
                return notifier.setMinutesBeforeLimit(value);
              },
            ),
          ),
        // Trigger value - hour angle threshold
        if (flipSettings.triggerMethod ==
            MeridianTriggerMethod.hourAngleThreshold)
          SettingRow(
            icon: LucideIcons.timer,
            title: 'Hour angle threshold',
            subtitle: 'Flip when hour angle exceeds this value',
            trailing: SettingsNumberInput(
              authoritativeValue: flipSettings.hourAngleThreshold,
              authorityKey: authority,
              suffix: 'h',
              min: 0,
              max: 6,
              decimals: 2,
              onChanged: (value) {
                return notifier.setHourAngleThreshold(value);
              },
            ),
          ),
        // Trigger value - tracking limit wait time
        if (flipSettings.triggerMethod ==
            MeridianTriggerMethod.onTrackingLimitHit)
          SettingRow(
            icon: LucideIcons.timer,
            title: 'Wait before flip',
            subtitle:
                'Delay after tracking limit detected (0 = flip immediately)',
            trailing: SettingsNumberInput(
              authoritativeValue: flipSettings.trackingLimitWaitMinutes,
              authorityKey: authority,
              suffix: 'min',
              min: 0,
              max: 60,
              decimals: 1,
              onChanged: (value) {
                return notifier.setTrackingLimitWaitMinutes(value);
              },
            ),
          ),
        // What a stop at the mount's own tracking limit does
        SettingRow(
          icon: LucideIcons.flipHorizontal2,
          title: 'When the mount stops at its limit',
          subtitle: flipSettings.trackingLimitPolicy.description,
          trailing: settingsTrailingChoice<TrackingLimitPolicy>(
            value: flipSettings.trackingLimitPolicy,
            values: TrackingLimitPolicy.values,
            labelOf: (policy) => policy.displayName,
            designWidth: 200,
            onChanged: notifier.setTrackingLimitPolicy,
          ),
        ),
        // Flip sequence - pause guiding
        SettingRow(
          icon: LucideIcons.pause,
          title: 'Pause guiding before flip',
          subtitle: 'Temporarily stop autoguider during flip',
          trailing: SettingsSwitch(
            value: flipSettings.pauseGuidingBeforeFlip,
            onChanged: (value) {
              return notifier.setPauseGuidingBeforeFlip(value);
            },
          ),
        ),
        // Flip sequence - recenter
        SettingRow(
          icon: LucideIcons.crosshair,
          title: 'Recenter after flip',
          subtitle: 'Plate solve and re-center target after flip',
          trailing: SettingsSwitch(
            value: flipSettings.recenterAfterFlip,
            onChanged: (value) {
              return notifier.setRecenterAfterFlip(value);
            },
          ),
        ),
        // Flip sequence - refocus
        SettingRow(
          icon: LucideIcons.focus,
          title: 'Refocus after flip',
          subtitle: 'Run autofocus after flip completes',
          trailing: SettingsSwitch(
            value: flipSettings.refocusAfterFlip,
            onChanged: (value) {
              return notifier.setRefocusAfterFlip(value);
            },
          ),
        ),
        // Flip sequence - resume guiding
        SettingRow(
          icon: LucideIcons.play,
          title: 'Resume guiding after flip',
          subtitle: 'Restart autoguider if it was running',
          trailing: SettingsSwitch(
            value: flipSettings.resumeGuidingAfterFlip,
            onChanged: (value) {
              return notifier.setResumeGuidingAfterFlip(value);
            },
          ),
        ),
        // Settle time
        SettingRow(
          icon: LucideIcons.clock,
          title: 'Settle time',
          subtitle: 'Wait time after flip before resuming',
          trailing: SettingsNumberInput(
            authoritativeValue: flipSettings.settleTimeSeconds,
            authorityKey: authority,
            suffix: 'sec',
            min: 0,
            max: 300,
            decimals: 0,
            onChanged: (value) {
              return notifier.setSettleTimeSeconds(value);
            },
          ),
        ),
        // Error handling - max retries
        SettingRow(
          icon: LucideIcons.repeat,
          title: 'Max retries',
          subtitle: 'Number of retry attempts if flip fails',
          trailing: SettingsNumberInput(
            authoritativeValue: flipSettings.maxRetries.toDouble(),
            authorityKey: authority,
            suffix: '',
            min: 0,
            max: 10,
            decimals: 0,
            onChanged: (value) {
              return notifier.setMaxRetries(value.toInt());
            },
          ),
        ),
        // Error handling - failure action
        SettingRow(
          icon: LucideIcons.alertTriangle,
          title: 'On failure',
          subtitle: flipSettings.failureAction.description,
          trailing: settingsTrailingChoice<FlipFailureAction>(
            value: flipSettings.failureAction,
            values: FlipFailureAction.values,
            labelOf: (action) => action.displayName,
            designWidth: 160,
            onChanged: notifier.setFailureAction,
          ),
        ),
        // Notifications - sound
        SettingRow(
          icon: LucideIcons.volume2,
          title: 'Sound alert',
          subtitle: 'Play sound when flip starts/completes/fails',
          trailing: SettingsSwitch(
            value: flipSettings.soundAlertOnFlip,
            onChanged: (value) {
              return notifier.setSoundAlertOnFlip(value);
            },
          ),
        ),
        // Notifications - push
        SettingRow(
          icon: LucideIcons.bell,
          title: 'Push notification',
          subtitle: 'Send notification to mobile app',
          trailing: SettingsSwitch(
            value: flipSettings.pushNotificationOnFlip,
            onChanged: (value) {
              return notifier.setPushNotificationOnFlip(value);
            },
          ),
          isLast: true,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final flipSettings = ref.watch(globalMeridianFlipSettingsProvider);
    final flipLoadState = ref.watch(
      globalMeridianFlipSettingsLoadStateProvider,
    );
    if (flipLoadState.isLoading) {
      return const SettingsLoadingState();
    }
    if (flipLoadState.hasError) {
      return SettingsErrorState(
        error: flipLoadState.error!,
        onRetry: () {
          ref.invalidate(globalMeridianFlipSettingsProvider);
        },
      );
    }

    return settingsAsync.when(
      loading: () => const SettingsLoadingState(),
      error: (error, stack) => SettingsErrorState(
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);
        final seqDefaults = ref.watch(sequencerDefaultsProvider);
        // This row and Weather Safety > "Auto-park mount" are two views of one
        // runtime gate (`parkOnUnsafeWeather && autoParkEnabled`). Show and
        // write the composed value from both places, otherwise turning this off
        // silently disarms auto-park while the other page still reads "on".
        final weatherSettings = ref.watch(weatherSettingsProvider);
        final autoParkOnUnsafe =
            settings.parkOnUnsafeWeather && weatherSettings.autoParkEnabled;

        return SettingsPage(
          hideHeader: false,
          title: 'Sequencer',
          description: 'Automation and sequence settings',
          children: [
            SettingsSection(
              title: 'Safety',
              children: [
                SettingRow(
                  icon: LucideIcons.shieldAlert,
                  title: 'Park on unsafe weather',
                  subtitle: 'Park the mount and close the cover and dome when '
                      'weather turns unsafe. When off, the run stops exposing '
                      'and waits for safe weather; nothing is parked or '
                      'closed. Same setting as Weather Safety > Auto-park '
                      'mount.',
                  trailing: SettingsSwitch(
                    value: autoParkOnUnsafe,
                    onChanged: (value) {
                      return ref
                          .read(weatherSettingsActionsProvider)
                          .setAutoParkOnUnsafe(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.sunrise,
                  title: 'Park before dawn',
                  subtitle:
                      'Park the mount and close the cover and dome 30 minutes '
                      'before astronomical dawn. When off, the run still ends '
                      'then, and nothing is parked or closed.',
                  trailing: SettingsSwitch(
                    value: settings.parkBeforeDawn,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setParkBeforeDawn(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.pauseOctagon,
                  title: 'Stop the run for quality problems',
                  subtitle: 'Off: when guiding RMS goes over its limit, a '
                      'centering or recenter cannot solve, a dither does not '
                      'settle, a post-flip check fails, the guide star cannot '
                      'be re-acquired (imaging goes on unguided) or the camera '
                      'cooler falls short of its set-point, you are notified '
                      'and the run keeps imaging. On: each of these pauses or '
                      'ends the run. Weather, dawn, a cooler fault and the '
                      'other safety rules act either way.',
                  trailing: SettingsSwitch(
                    value: settings.stopRunOnQualityProblems,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setStopRunOnQualityProblems(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.crosshair,
                  title: 'Recover the mount on its own after a mount fault',
                  subtitle: 'When the mount moves on its own or loses its '
                      'position, the run pauses and Skotiq stops moving the '
                      'mount. Off: you recover the position (re-home it, or '
                      'plate solve and sync) and resume. On: once the mount '
                      'has been still for 30 s, Skotiq takes a frame, plate '
                      'solves it, syncs the mount and resumes the run, which '
                      'centers on its target first.',
                  trailing: SettingsSwitch(
                    value: settings.mountGuardAutoSyncResume,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setMountGuardAutoSyncResume(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.alertTriangle,
                  title: 'Safety fail mode',
                  subtitle: settings.safetyFailMode.description,
                  trailing: settingsTrailingChoice<SafetyFailMode>(
                    value: settings.safetyFailMode,
                    values: SafetyFailModeLabels.choices,
                    labelOf: (mode) => mode.label,
                    designWidth: 180,
                    onChanged: (mode) => ref
                        .read(appSettingsProvider.notifier)
                        .setSafetyFailMode(mode),
                  ),
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Device retries',
              children: [
                SettingRow(
                  icon: LucideIcons.camera,
                  title: 'Camera retries',
                  subtitle: 'Times a failed exposure or image download is '
                      'tried again, after a short wait, before the run '
                      'treats it as a failure. Each retry is listed under '
                      'Session warnings. A camera that reports it is '
                      'disconnected goes to reconnect recovery instead. '
                      '0 tries once.',
                  trailing: SettingsNumberInput(
                    suffix: 'retries',
                    authoritativeValue: settings.cameraRetries.toDouble(),
                    authorityKey: authority,
                    min: 0,
                    max: kMaxDeviceRetries.toDouble(),
                    decimals: 0,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setCameraRetries(value.toInt());
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.disc,
                  title: 'Filter wheel retries',
                  subtitle: 'Times a failed filter change, or one where the '
                      'wheel never reaches the filter, is tried again before '
                      'the run treats it as a failure. 0 tries once.',
                  trailing: SettingsNumberInput(
                    suffix: 'retries',
                    authoritativeValue: settings.filterWheelRetries.toDouble(),
                    authorityKey: authority,
                    min: 0,
                    max: kMaxDeviceRetries.toDouble(),
                    decimals: 0,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setFilterWheelRetries(value.toInt());
                    },
                  ),
                  isLast: true,
                ),
              ],
            ),
            _buildMeridianFlipSection(flipSettings, authority),
            SettingsSection(
              title: 'Auto focus',
              children: [
                SettingRow(
                  icon: LucideIcons.focus,
                  title: 'Auto focus on filter change',
                  subtitle: 'Run auto focus when switching filters',
                  trailing: SettingsSwitch(
                    value: settings.autoFocusOnFilterChange,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setAutoFocusOnFilterChange(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.timer,
                  title: 'Auto focus interval',
                  subtitle: 'Run auto focus periodically',
                  trailing: SettingsNumberInput(
                    authoritativeValue:
                        settings.autoFocusEveryMinutes.toDouble(),
                    authorityKey: authority,
                    suffix: 'min',
                    min: 0,
                    max: 240,
                    decimals: 0,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setAutoFocusEveryMinutes(value.toInt());
                    },
                  ),
                ),
                // Frames-based AutofocusInterval cadence: the right number
                // depends on the sub length. The run configuration follows
                // the saved value, so a running sequence takes the change.
                SettingRow(
                  icon: LucideIcons.repeat,
                  title: 'Auto focus every N frames',
                  subtitle:
                      'Run autofocus every N completed exposures (frames-based)',
                  trailing: SettingsNumberInput(
                    authoritativeValue:
                        seqDefaults.autofocusIntervalFrames.toDouble(),
                    authorityKey: authority,
                    suffix: 'frames',
                    min: 1,
                    max: 9999,
                    decimals: 0,
                    onChanged: (value) async {
                      await ref
                          .read(sequencerDefaultsProvider.notifier)
                          .updateAutofocusDefaults(
                            intervalFrames: value.toInt(),
                          );
                    },
                  ),
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Dithering',
              children: [
                SettingRow(
                  icon: LucideIcons.move,
                  title: 'Enable dithering',
                  subtitle: 'Move mount slightly between exposures',
                  trailing: SettingsSwitch(
                    value: settings.ditherEnabled,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setDitherEnabled(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.hash,
                  title: 'Dither every',
                  subtitle: 'Number of frames between dithers',
                  trailing: SettingsNumberInput(
                    authoritativeValue: settings.ditherEveryFrames.toDouble(),
                    authorityKey: authority,
                    suffix: 'frames',
                    min: 1,
                    max: 20,
                    decimals: 0,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setDitherEveryFrames(value.toInt());
                    },
                  ),
                  isLast: true,
                ),
              ],
            ),
            // Live Stacking & Broadcast defaults. New
            // LiveStackingNodes inherit these knobs (port, stack method,
            // watermark template, thumbnail size, public-by-default,
            // master kill switch). Sits between Dithering and Notes
            // because it logically follows the per-frame capture
            // pipeline knobs above and precedes the post-run journaling
            // surface below.
            _buildBroadcastSection(seqDefaults, authority),
            // Notes prompt opt-out lives here under
            // Sequencer because the prompt fires at sequence-run end.
            // Placed before Development so the user always sees the
            // toggle (Development section is hidden in release builds).
            SettingsSection(
              title: 'Notes & journal',
              children: [
                SettingRow(
                  icon: LucideIcons.bookOpen,
                  title: 'Prompt for notes after run',
                  subtitle: 'Show a quick journal-entry dialog when a sequence '
                      'finishes so you can capture seeing, dew, anomalies.',
                  trailing: SettingsSwitch(
                    value: settings.promptForNotesAfterRun,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setPromptForNotesAfterRun(value);
                    },
                  ),
                  isLast: true,
                ),
              ],
            ),
            // Smart Night defaults live here too because
            // they all govern sequence-builder behaviour. The wizard
            // mutates these values as the user adjusts knobs, and reads
            // them back on next launch so preferences persist across
            // restarts.
            SettingsSection(
              title: 'Smart night defaults',
              children: [
                SettingRow(
                  icon: LucideIcons.focus,
                  title: 'Autofocus cadence (frames)',
                  subtitle: 'How many exposures between autofocus runs '
                      'when the wizard picks frame-based cadence.',
                  trailing: SettingsNumberInput(
                    authoritativeValue:
                        settings.smartNightDefaultAfCadenceFrames.toDouble(),
                    authorityKey: authority,
                    suffix: 'frames',
                    min: 1,
                    max: 9999,
                    decimals: 0,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setSmartNightDefaultAfCadenceFrames(value.toInt());
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.clock,
                  title: 'Integration budget per target',
                  subtitle:
                      'Default per-target imaging budget the wizard uses.',
                  trailing: SettingsNumberInput(
                    authoritativeValue: settings
                        .smartNightDefaultIntegrationBudgetMinsPerTarget
                        .toDouble(),
                    authorityKey: authority,
                    suffix: 'min',
                    min: 1,
                    max: 24 * 60,
                    decimals: 0,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setSmartNightDefaultIntegrationBudgetMinsPerTarget(
                            value.toInt(),
                          );
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.lamp,
                  title: 'Include flats at end',
                  subtitle: 'Append per-filter flats when the active '
                      'profile has a cover calibrator.',
                  trailing: SettingsSwitch(
                    value: settings.smartNightIncludeFlatsAtEnd,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setSmartNightIncludeFlatsAtEnd(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.listOrdered,
                  title: 'Scheduler for multi-target nights',
                  subtitle: 'Wrap multi-target plans in a TargetScheduler so '
                      'the executor can swap between them by altitude.',
                  trailing: SettingsSwitch(
                    value: settings.smartNightUseSchedulerForMultiTarget,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setSmartNightUseSchedulerForMultiTarget(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.hash,
                  title: 'Scheduler threshold (targets)',
                  subtitle: 'Use the scheduler when target count reaches this '
                      'number; otherwise chain them linearly.',
                  trailing: SettingsNumberInput(
                    authoritativeValue:
                        settings.smartNightSchedulerTargetThreshold.toDouble(),
                    authorityKey: authority,
                    suffix: '',
                    min: 2,
                    max: 20,
                    decimals: 0,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setSmartNightSchedulerTargetThreshold(value.toInt());
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.compass,
                  title: 'Polar alignment stale after',
                  subtitle: 'If the last polar alignment is older than '
                      'this, the wizard prepends a fresh alignment node.',
                  trailing: SettingsNumberInput(
                    authoritativeValue: settings
                        .smartNightPolarAlignmentStaleAfterDays
                        .toDouble(),
                    authorityKey: authority,
                    suffix: 'days',
                    min: 1,
                    max: 365,
                    decimals: 0,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setSmartNightPolarAlignmentStaleAfterDays(
                            value.toInt(),
                          );
                    },
                  ),
                  isLast: true,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
