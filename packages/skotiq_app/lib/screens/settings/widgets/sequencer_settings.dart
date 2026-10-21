import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../widgets/help/field_help_copy.dart';
import 'safety_fail_mode_labels.dart';
import 'settings_widgets.dart';

class SequencerSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const SequencerSettings({super.key, this.isMobile = false});

  @override
  ConsumerState<SequencerSettings> createState() => _SequencerSettingsState();
}

class _SequencerSettingsState extends ConsumerState<SequencerSettings> {
  // Live Stacking & Broadcast settings controllers. The
  // watermark template is kept as a TextEditingController so the
  // VariablePicker can splice values into the caret position; the port
  // input shares the same SettingsNumberInput pattern used by the rest of
  // the page.
  final _broadcastPortController = TextEditingController();
  final _broadcastWatermarkController = TextEditingController();

  // Sequencer settings controllers
  final _autoFocusController = TextEditingController();
  // Frames-based cadence for the standard AutofocusInterval
  // trigger. Distinct from `_autoFocusController` (which is in minutes for the
  // app-level AppSettings UX) — this one targets the Rust trigger directly.
  final _autoFocusIntervalFramesController = TextEditingController();
  final _ditherController = TextEditingController();
  final _cameraRetriesController = TextEditingController();
  final _filterWheelRetriesController = TextEditingController();

  // Smart Night default controllers. Hoisted (rather than allocated inline in
  // build) so a per-keystroke provider rebuild doesn't recreate them and reset
  // the caret while the user is typing.
  final _smartNightAfCadenceController = TextEditingController();
  final _smartNightIntegrationBudgetController = TextEditingController();
  final _smartNightSchedulerThresholdController = TextEditingController();
  final _smartNightPolarStaleController = TextEditingController();

  // Meridian flip settings controllers
  final _minutesPastMeridianController = TextEditingController();
  final _minutesBeforeLimitController = TextEditingController();
  final _hourAngleThresholdController = TextEditingController();
  final _trackingLimitWaitController = TextEditingController();
  final _pauseBeforeMeridianController = TextEditingController();
  final _settleTimeController = TextEditingController();
  final _maxRetriesController = TextEditingController();

  @override
  void dispose() {
    _autoFocusController.dispose();
    _autoFocusIntervalFramesController.dispose();
    _ditherController.dispose();
    _cameraRetriesController.dispose();
    _filterWheelRetriesController.dispose();
    _smartNightAfCadenceController.dispose();
    _smartNightIntegrationBudgetController.dispose();
    _smartNightSchedulerThresholdController.dispose();
    _smartNightPolarStaleController.dispose();
    _minutesPastMeridianController.dispose();
    _minutesBeforeLimitController.dispose();
    _hourAngleThresholdController.dispose();
    _trackingLimitWaitController.dispose();
    _pauseBeforeMeridianController.dispose();
    _settleTimeController.dispose();
    _maxRetriesController.dispose();
    _broadcastPortController.dispose();
    _broadcastWatermarkController.dispose();
    super.dispose();
  }

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
          icon: LucideIcons.network,
          title: 'Default broadcast port',
          subtitle: 'Port used by newly-created LiveStacking nodes. '
              'Must not clash with the headless API server.',
          trailing: SettingsNumberInput(
            controller: _broadcastPortController,
            authoritativeValue: defaults.livestackingDefaultPort.toDouble(),
            authorityKey: authority,
            suffix: '',
            min: 1,
            max: 65535,
            decimals: 0,
            onChanged: (value) {
              return notifier.updateLiveStackingDefaults(
                defaultPort: value.toInt(),
              );
            },
          ),
        ),
        SettingRow(
          icon: LucideIcons.layers,
          title: 'Default stack method',
          subtitle: 'Average is fastest; Median + Rejection and Sigma '
              'reject outliers but are slower.',
          trailing: settingsTrailingDropdown(
            context: context,
            value: defaults.livestackingDefaultStackMethod.label,
            items: LiveStackingMethod.values.map((m) => m.label).toList(),
            designWidth: 200,
            isMobile: widget.isMobile,
            onChanged: (value) {
              final method = LiveStackingMethod.values.firstWhere(
                (m) => m.label == value,
                orElse: () => LiveStackingMethod.average,
              );
              return notifier.updateLiveStackingDefaults(
                defaultStackMethod: method,
              );
            },
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
            controller: _broadcastWatermarkController,
            authoritativeValue: defaults.livestackingDefaultWatermark ?? '',
            authorityKey: authority,
            hint: 'e.g. M42 — \${integration.hms}',
            designWidth: 240,
            isMobile: widget.isMobile,
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
          trailing: settingsTrailingDropdown(
            context: context,
            value: defaults.livestackingDefaultThumbnailSize.label,
            items:
                LiveStackingThumbnailSize.values.map((s) => s.label).toList(),
            designWidth: 220,
            isMobile: widget.isMobile,
            onChanged: (value) {
              final picked = LiveStackingThumbnailSize.values.firstWhere(
                (s) => s.label == value,
                orElse: () => LiveStackingThumbnailSize.medium,
              );
              return notifier.updateLiveStackingDefaults(
                defaultThumbnailSize: picked,
              );
            },
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
          trailing: settingsTrailingDropdown(
            context: context,
            value: flipSettings.triggerMethod.displayName,
            items:
                MeridianTriggerMethod.values.map((e) => e.displayName).toList(),
            designWidth: 200,
            isMobile: widget.isMobile,
            onChanged: (value) {
              final method = MeridianTriggerMethod.values.firstWhere(
                (e) => e.displayName == value,
              );
              return notifier.setTriggerMethod(method);
            },
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
              controller: _minutesPastMeridianController,
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
              controller: _pauseBeforeMeridianController,
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
              controller: _minutesBeforeLimitController,
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
              controller: _hourAngleThresholdController,
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
              controller: _trackingLimitWaitController,
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
            controller: _settleTimeController,
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
            controller: _maxRetriesController,
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
          trailing: settingsTrailingDropdown(
            context: context,
            value: flipSettings.failureAction.displayName,
            items: FlipFailureAction.values.map((e) => e.displayName).toList(),
            designWidth: 160,
            isMobile: widget.isMobile,
            onChanged: (value) {
              final action = FlipFailureAction.values.firstWhere(
                (e) => e.displayName == value,
              );
              return notifier.setFailureAction(action);
            },
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
      return SettingsLoadingState(isMobile: widget.isMobile);
    }
    if (flipLoadState.hasError) {
      return SettingsErrorState(
        isMobile: widget.isMobile,
        error: flipLoadState.error!,
        onRetry: () {
          ref.invalidate(globalMeridianFlipSettingsProvider);
        },
      );
    }

    return settingsAsync.when(
      loading: () => SettingsLoadingState(isMobile: widget.isMobile),
      error: (error, stack) => SettingsErrorState(
        isMobile: widget.isMobile,
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
                  icon: LucideIcons.alertTriangle,
                  title: 'Safety fail mode',
                  subtitle: settings.safetyFailMode.description,
                  trailing: settingsTrailingDropdown(
                    context: context,
                    value: settings.safetyFailMode.label,
                    items: SafetyFailModeLabels.labels,
                    designWidth: 180,
                    isMobile: widget.isMobile,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setSafetyFailMode(
                            SafetyFailModeLabels.fromLabel(value),
                          );
                    },
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
                    controller: _cameraRetriesController,
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
                    controller: _filterWheelRetriesController,
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
                    controller: _autoFocusController,
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
                // Frames-based AutofocusInterval cadence.
                // The Rust standard trigger ships with `every_n_frames = 25`
                // which is wildly wrong for both 5-second and 5-minute subs;
                // exposing this number directly lets the user tune the
                // cadence to their actual sub-exposure length. Pushed to the
                // executor immediately so a mid-sequence change takes effect.
                SettingRow(
                  icon: LucideIcons.repeat,
                  title: 'Auto focus every N frames',
                  subtitle:
                      'Run autofocus every N completed exposures (frames-based)',
                  trailing: SettingsNumberInput(
                    controller: _autoFocusIntervalFramesController,
                    authoritativeValue:
                        seqDefaults.autofocusIntervalFrames.toDouble(),
                    authorityKey: authority,
                    suffix: 'frames',
                    min: 1,
                    max: 9999,
                    decimals: 0,
                    onChanged: (value) async {
                      final frames = value.toInt();
                      final sequencerBackend = ref.read(
                        sequencerBackendProvider,
                      );
                      // Persist via SequencerDefaults so the value survives
                      // restart and is consulted by the executor on start().
                      await ref
                          .read(sequencerDefaultsProvider.notifier)
                          .updateAutofocusDefaults(intervalFrames: frames);
                      // Push to the live executor so an in-flight sequence
                      // honours the new cadence without a reload. The bridge
                      // function rejects 0, which we already clamp at 1.
                      try {
                        if (!identical(ref.read(backendProvider), authority)) {
                          return;
                        }
                        await sequencerBackend.sequencerUpdateAutofocusInterval(
                          frames,
                        );
                      } catch (e) {
                        // Surfacing the error via a snackbar would be noisy;
                        // the executor will pick up the persisted value on
                        // its next start() regardless.
                        debugPrint(
                          'Failed to push autofocus interval to executor: $e',
                        );
                      }
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
                    controller: _ditherController,
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
                    controller: _smartNightAfCadenceController,
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
                    controller: _smartNightIntegrationBudgetController,
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
                    controller: _smartNightSchedulerThresholdController,
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
                    controller: _smartNightPolarStaleController,
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
