import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../push_delivery_targets_provider.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../tours/tour_target.dart';
import 'admin_only.dart';
import 'notification_routing_settings.dart';
import 'settings_widgets.dart';

/// Subtitle for the "Push critical alerts to mobile" row.
///
/// Reports the host's real delivery state rather than restating the toggle's
/// intent. The row is a preference switch, so it stays operable — but it must
/// not imply that turning it on makes alerts arrive when nothing can receive
/// them.
String pushDeliverySubtitleFor(AsyncValue<PushDeliveryTargets> async) {
  if (async.isLoading && !async.hasValue) {
    return 'Checking which devices can receive push alerts…';
  }
  final targets = async.valueOrNull ?? PushDeliveryTargets.none;
  if (targets.canDeliver) {
    final devices = targets.registeredDeviceCount;
    return devices == 1
        ? 'Delivering to 1 registered device'
        : 'Delivering to $devices registered devices';
  }
  final reason = targets.blockedReason ?? 'Push delivery is unavailable';
  return '$reason. Until then a critical alert shows only in the app, while '
      'it is open on your network.';
}

/// Subtitle for one of the three switches over Skotiq's own alerts.
///
/// The switches are live: `NotificationService.notify` refuses the whole
/// alert for a family whose flag is off (see `_shouldNotifyForEvent`), so it
/// plays no sound and is sent nowhere. Run events the router reads from the
/// event stream are not affected.
///
/// [sends] says what the family covers. [offByDefault] is true for meridian
/// flip alone, whose stored default is off: the one row where off is
/// Skotiq's choice rather than the owner's, which someone expecting a flip
/// alert has to be told.
String builtInEventAlertSubtitle(
  String sends, {
  required bool enabled,
  bool offByDefault = false,
}) {
  if (enabled) {
    return '$sends Sent where Other alerts go, below.';
  }
  return offByDefault
      ? '$sends Off until you turn it on.'
      : '$sends Off: none are sent.';
}

class NotificationSettings extends ConsumerStatefulWidget {
  const NotificationSettings({super.key});

  @override
  ConsumerState<NotificationSettings> createState() =>
      _NotificationSettingsState();
}

class _NotificationSettingsState extends ConsumerState<NotificationSettings> {
  final _discordController = TextEditingController();
  final _pushoverKeyController = TextEditingController();
  final _pushoverUserController = TextEditingController();
  _NotificationTest? _activeTest;
  int _testGeneration = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next)) return;
        _testGeneration++;
        if (mounted && _activeTest != null) {
          setState(() => _activeTest = null);
        }
      },
    );
  }

  @override
  void dispose() {
    _testGeneration++;
    _backendSubscription?.close();
    _discordController.dispose();
    _pushoverKeyController.dispose();
    _pushoverUserController.dispose();
    super.dispose();
  }

  Future<void> _testDiscord() async {
    if (_activeTest != null) return;
    final webhook = _discordController.text.trim();
    if (webhook.isEmpty) {
      context.showWarningSnackBar('Please enter a Discord webhook URL');
      return;
    }

    final authority = ref.read(backendProvider);
    final generation = ++_testGeneration;
    setState(() => _activeTest = _NotificationTest.discord);
    try {
      final result = await ref.read(notificationTransportProbeProvider)(
        DiscordTransport(config: DiscordTransportConfig(webhookUrl: webhook)),
      );
      final success = result.success;
      if (mounted &&
          _isCurrentTest(
            authority,
            generation,
            _NotificationTest.discord,
          )) {
        if (success) {
          context.showSuccessSnackBar(
              'Discord test notification sent successfully!');
        } else {
          context.showErrorSnackBar(
              'Failed to send Discord notification. Check your webhook URL.');
        }
      }
    } catch (e) {
      if (mounted &&
          _isCurrentTest(
            authority,
            generation,
            _NotificationTest.discord,
          )) {
        context.showErrorSnackBar(
          'Failed to test Discord notification: ${userFacingError(e)}',
        );
      }
    } finally {
      if (mounted &&
          _isCurrentTest(
            authority,
            generation,
            _NotificationTest.discord,
          )) {
        setState(() => _activeTest = null);
      }
    }
  }

  Future<void> _testPushover() async {
    if (_activeTest != null) return;
    final key = _pushoverKeyController.text.trim();
    final user = _pushoverUserController.text.trim();
    if (key.isEmpty || user.isEmpty) {
      context.showWarningSnackBar('Please enter both API key and User key');
      return;
    }

    final authority = ref.read(backendProvider);
    final generation = ++_testGeneration;
    setState(() => _activeTest = _NotificationTest.pushover);
    try {
      final result = await ref.read(notificationTransportProbeProvider)(
        PushoverTransport(
          config: PushoverTransportConfig(apiToken: key, userKey: user),
        ),
      );
      final success = result.success;
      if (mounted &&
          _isCurrentTest(
            authority,
            generation,
            _NotificationTest.pushover,
          )) {
        if (success) {
          context.showSuccessSnackBar(
              'Pushover test notification sent successfully!');
        } else {
          context.showErrorSnackBar(
              'Failed to send Pushover notification. Check your API and User keys.');
        }
      }
    } catch (e) {
      if (mounted &&
          _isCurrentTest(
            authority,
            generation,
            _NotificationTest.pushover,
          )) {
        context.showErrorSnackBar(
          'Failed to test Pushover notification: ${userFacingError(e)}',
        );
      }
    } finally {
      if (mounted &&
          _isCurrentTest(
            authority,
            generation,
            _NotificationTest.pushover,
          )) {
        setState(() => _activeTest = null);
      }
    }
  }

  Future<void> _testPushToMobile() async {
    if (_activeTest != null) return;
    final authority = ref.read(backendProvider);
    final generation = ++_testGeneration;
    setState(() => _activeTest = _NotificationTest.push);
    try {
      final pushService = ref.read(pushNotificationServiceProvider);
      await pushService.sendTestNotification();
      if (mounted &&
          _isCurrentTest(authority, generation, _NotificationTest.push)) {
        context.showSuccessSnackBar(
          'Test sent. A phone receives it once it is paired and has '
          'registered for push.',
        );
      }
    } catch (e) {
      if (mounted &&
          _isCurrentTest(authority, generation, _NotificationTest.push)) {
        context.showErrorSnackBar(
          'Failed to send test notification: ${userFacingError(e)}',
        );
      }
    } finally {
      if (_isCurrentTest(authority, generation, _NotificationTest.push)) {
        setState(() => _activeTest = null);
      }
    }
  }

  bool _isCurrentTest(
    SkotiqBackend authority,
    int generation,
    _NotificationTest test,
  ) =>
      mounted &&
      generation == _testGeneration &&
      _activeTest == test &&
      ref.backendScopeOver(authority).isCurrent;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final authority = ref.watch(backendProvider);
    final isRemoteController = ref.watch(isRemoteModeProvider);
    final credentialsHidden = hostRefusesAdminOnly(ref);
    final AsyncValue<PushNotificationConfig>? pushConfigAsync =
        isRemoteController ? null : ref.watch(pushNotificationConfigProvider);
    // Real delivery state, so the critical-alert row can stop asserting a
    // capability the system may not have.
    final pushTargetsAsync = ref.watch(pushDeliveryTargetsProvider);
    final pushTargets =
        pushTargetsAsync.valueOrNull ?? PushDeliveryTargets.none;

    return settingsAsync.when(
      loading: () => const SettingsLoadingState(),
      error: (error, stack) => SettingsErrorState(
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final pushConfig = pushConfigAsync?.valueOrNull ??
            const PushNotificationConfig(enabled: false);
        final pushConfigReady = pushConfigAsync != null &&
            pushConfigAsync.hasValue &&
            !pushConfigAsync.isLoading &&
            !pushConfigAsync.hasError;

        return SettingsPage(
          hideHeader: false,
          key: TourTarget.settingsNotifications.key,
          title: 'Notifications',
          description: 'What Skotiq tells you about, and where it sends it.',
          children: [
            SettingsSection(
              title: "Skotiq's own alerts",
              children: [
                SettingRow(
                  icon: LucideIcons.bell,
                  title: 'Send these alerts',
                  subtitle: 'The end of the night, errors and meridian flips, '
                      'below. Off sends none of them. Run events further '
                      'down are not affected.',
                  trailing: SettingsSwitch(
                    value: settings.notificationsEnabled,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setNotificationsEnabled(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.volume2,
                  title: 'Sound',
                  subtitle: 'Play a short sound in the app with each of them.',
                  trailing: SettingsSwitch(
                    value: settings.soundEnabled,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setSoundEnabled(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.checkCircle,
                  title: 'End of the night',
                  subtitle: builtInEventAlertSubtitle(
                    'The morning message, finished masters and the '
                    'end-of-night calibration.',
                    enabled: settings.notifyOnSequenceComplete,
                  ),
                  trailing: SettingsSwitch(
                    value: settings.notifyOnSequenceComplete,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setNotifyOnSequenceComplete(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.alertCircle,
                  title: 'Errors',
                  subtitle: builtInEventAlertSubtitle(
                    'A capture that failed, or a device that would not '
                    'reconnect.',
                    enabled: settings.notifyOnError,
                  ),
                  trailing: SettingsSwitch(
                    value: settings.notifyOnError,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setNotifyOnError(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.rotateCw,
                  title: 'Meridian flip',
                  subtitle: builtInEventAlertSubtitle(
                    'When the mount starts and finishes a flip.',
                    enabled: settings.notifyOnMeridianFlip,
                    offByDefault: true,
                  ),
                  trailing: SettingsSwitch(
                    value: settings.notifyOnMeridianFlip,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setNotifyOnMeridianFlip(value);
                    },
                  ),
                  isLast: true,
                ),
              ],
            ),
            // A critical problem reaches the owner who has walked away from
            // the computer: a sound in the room and a push to the phone.
            SettingsSection(
              title: 'Critical problems during a run',
              children: [
                SettingRow(
                  icon: LucideIcons.bellRing,
                  title: 'Ring on this computer',
                  subtitle: 'Sound an alarm here when a run hits a critical '
                      'problem, such as a mount fault or a failed recovery.',
                  trailing: SettingsSwitch(
                    value: settings.audibleAlertsOnCritical,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setAudibleAlertsOnCritical(value);
                    },
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.volume2,
                  title: 'Alarm sound',
                  subtitle: 'What rings.',
                  trailing: SettingsDropdown(
                    value: settings.criticalAlertSound,
                    items: const ['systemBell', 'none'],
                    itemLabels: const ['System bell', 'None (silent)'],
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setCriticalAlertSound(value);
                    },
                  ),
                ),
                // The switch is a PREFERENCE ("forward criticals when you
                // can"), not a statement of capability — on Android in a stock
                // build the FCM client is a dormant scaffold pending Firebase
                // provisioning, so no phone ever registers a token. The
                // subtitle therefore reports the host's ACTUAL delivery state
                // rather than the intent.
                SettingRow(
                  icon: pushTargets.canDeliver
                      ? LucideIcons.smartphone
                      : LucideIcons.smartphoneNfc,
                  title: 'Send to paired phones',
                  subtitle: pushDeliverySubtitleFor(pushTargetsAsync),
                  trailing: SettingsSwitch(
                    value: settings.pushCriticalAlerts,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setPushCriticalAlerts(value);
                    },
                  ),
                  isLast: true,
                ),
              ],
            ),
            if (isRemoteController)
              const SettingsSection(
                title: 'Push to phones',
                children: [
                  SettingRow(
                    icon: LucideIcons.server,
                    title: 'Set on the imaging computer',
                    subtitle: 'Which events reach phones is set on the '
                        'computer that runs the rig.',
                    trailing: SizedBox.shrink(),
                    isLast: true,
                  ),
                ],
              )
            else if (pushConfigAsync!.isLoading)
              SettingsSection(
                title: 'Push to phones',
                children: [
                  SettingRow(
                    icon: LucideIcons.smartphone,
                    title: 'Loading',
                    subtitle: 'The phone settings appear once they have '
                        'loaded.',
                    trailing: SizedBox(
                      width: 18,
                      height: 18,
                      child: SkotiqSpinner(
                          size: 18, color: SkotiqColors.of(context).primary),
                    ),
                    isLast: true,
                  ),
                ],
              )
            else if (pushConfigAsync.hasError)
              SettingsSection(
                title: 'Push to phones',
                children: [
                  SettingRow(
                    icon: LucideIcons.alertTriangle,
                    title: 'Could not load the phone settings',
                    subtitle: userFacingError(pushConfigAsync.error),
                    trailing: SkotiqButton(
                      label: 'Retry',
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      onPressed: () =>
                          ref.invalidate(pushNotificationConfigProvider),
                    ),
                    isLast: true,
                  ),
                ],
              ),
            if (pushConfigReady)
              SettingsSection(
                title: 'Push to phones',
                children: [
                  SettingRow(
                    icon: LucideIcons.smartphone,
                    title: 'Push to phones',
                    subtitle: 'Send these events to phones paired with this '
                        'computer. Each one can be turned off here.',
                    trailing: SettingsSwitch(
                      value: pushConfig.enabled,
                      onChanged: (value) {
                        return ref
                            .read(pushNotificationConfigProvider.notifier)
                            .setEnabled(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.checkCircle,
                    title: 'Sequence completed',
                    subtitle: 'When a run finishes.',
                    trailing: SettingsSwitch(
                      value: pushConfig.notifySequenceCompleted,
                      enabled: pushConfig.enabled,
                      onChanged: (value) {
                        return ref
                            .read(pushNotificationConfigProvider.notifier)
                            .setNotifySequenceCompleted(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.alertTriangle,
                    title: 'Sequence failed',
                    subtitle: 'When a run fails or is stopped.',
                    trailing: SettingsSwitch(
                      value: pushConfig.notifySequenceFailed,
                      enabled: pushConfig.enabled,
                      onChanged: (value) {
                        return ref
                            .read(pushNotificationConfigProvider.notifier)
                            .setNotifySequenceFailed(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.rotateCw,
                    title: 'Meridian flip',
                    subtitle: 'When the mount flips.',
                    trailing: SettingsSwitch(
                      value: pushConfig.notifyMeridianFlip,
                      enabled: pushConfig.enabled,
                      onChanged: (value) {
                        return ref
                            .read(pushNotificationConfigProvider.notifier)
                            .setNotifyMeridianFlip(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.cloudRain,
                    title: 'Weather unsafe',
                    subtitle: 'When the weather turns unsafe.',
                    trailing: SettingsSwitch(
                      value: pushConfig.notifyWeatherUnsafe,
                      enabled: pushConfig.enabled,
                      onChanged: (value) {
                        return ref
                            .read(pushNotificationConfigProvider.notifier)
                            .setNotifyWeatherUnsafe(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.crosshair,
                    title: 'Guiding lost',
                    subtitle: 'When the guide star stays lost.',
                    trailing: SettingsSwitch(
                      value: pushConfig.notifyGuidingLost,
                      enabled: pushConfig.enabled,
                      onChanged: (value) {
                        return ref
                            .read(pushNotificationConfigProvider.notifier)
                            .setNotifyGuidingLost(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.cameraOff,
                    title: 'Exposure failed',
                    subtitle: 'When an exposure fails.',
                    trailing: SettingsSwitch(
                      value: pushConfig.notifyExposureFailed,
                      enabled: pushConfig.enabled,
                      onChanged: (value) {
                        return ref
                            .read(pushNotificationConfigProvider.notifier)
                            .setNotifyExposureFailed(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.focus,
                    title: 'Autofocus failed',
                    subtitle: 'When autofocus fails.',
                    trailing: SettingsSwitch(
                      value: pushConfig.notifyAutofocusFailed,
                      enabled: pushConfig.enabled,
                      onChanged: (value) {
                        return ref
                            .read(pushNotificationConfigProvider.notifier)
                            .setNotifyAutofocusFailed(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.unplug,
                    title: 'Equipment disconnected',
                    subtitle: 'When a device drops.',
                    trailing: SettingsSwitch(
                      value: pushConfig.notifyEquipmentDisconnected,
                      enabled: pushConfig.enabled,
                      onChanged: (value) {
                        return ref
                            .read(pushNotificationConfigProvider.notifier)
                            .setNotifyEquipmentDisconnected(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.send,
                    title: 'Send a test',
                    subtitle: 'Sends a test to paired phones. If it does not '
                        'arrive, the log says why.',
                    trailing: SkotiqButton(
                      label: 'Send test',
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      isLoading: _activeTest == _NotificationTest.push,
                      onPressed: (pushConfig.enabled && _activeTest == null)
                          ? _testPushToMobile
                          : null,
                    ),
                    isLast: true,
                  ),
                ],
              ),
            // A linked client cannot reach the host's keyring, so it edits
            // the host's Discord and Pushover credentials through the three
            // app settings that sync to the host; the host turns each edit
            // into its transport config. On the host itself the sections
            // inside NotificationRoutingSettings below are the only form.
            if (isRemoteController)
              SettingsSection(
                title: 'Discord',
                children: [
                  SettingRow(
                    icon: LucideIcons.messageSquare,
                    title: 'Webhook URL',
                    subtitle: 'The Discord channel alerts are posted to.',
                    isLast: credentialsHidden,
                    trailing: AdminOnlyControl(
                      text: adminOnlyCredentialAdvice(settings.discordWebhook),
                      child: settingsTrailingTextInput(
                        context: context,
                        controller: _discordController,
                        authoritativeValue: settings.discordWebhook,
                        authorityKey: authority,
                        hint: 'https://discord.com/api/webhooks/...',
                        obscure: true,
                        onChanged: (value) {
                          return ref
                              .read(appSettingsProvider.notifier)
                              .setDiscordWebhook(value);
                        },
                      ),
                    ),
                  ),
                  // The test sends from this computer with the typed URL,
                  // which a link without admin access never has.
                  if (!credentialsHidden)
                    SettingRow(
                      icon: LucideIcons.send,
                      title: 'Test Discord',
                      subtitle: 'Post a test message to the channel.',
                      trailing: SkotiqButton(
                        label: 'Send test',
                        variant: ButtonVariant.secondary,
                        size: ButtonSize.small,
                        isLoading: _activeTest == _NotificationTest.discord,
                        onPressed: _activeTest == null ? _testDiscord : null,
                      ),
                      isLast: true,
                    ),
                ],
              ),
            if (isRemoteController)
              SettingsSection(
                title: 'Pushover',
                children: [
                  SettingRow(
                    icon: LucideIcons.key,
                    title: 'API key',
                    subtitle: 'The key of your Pushover application.',
                    trailing: AdminOnlyControl(
                      text: adminOnlyCredentialAdvice(settings.pushoverKey),
                      child: SettingsTextInput(
                        controller: _pushoverKeyController,
                        authoritativeValue: settings.pushoverKey,
                        authorityKey: authority,
                        hint: 'API key',
                        width: 200,
                        obscure: true,
                        onChanged: (value) {
                          return ref
                              .read(appSettingsProvider.notifier)
                              .setPushoverKey(value);
                        },
                      ),
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.user,
                    title: 'User key',
                    subtitle: 'Your Pushover user or group key.',
                    isLast: credentialsHidden,
                    trailing: AdminOnlyControl(
                      text: adminOnlyCredentialAdvice(settings.pushoverUser),
                      child: SettingsTextInput(
                        controller: _pushoverUserController,
                        authoritativeValue: settings.pushoverUser,
                        authorityKey: authority,
                        hint: 'User key',
                        width: 200,
                        obscure: true,
                        onChanged: (value) {
                          return ref
                              .read(appSettingsProvider.notifier)
                              .setPushoverUser(value);
                        },
                      ),
                    ),
                  ),
                  if (!credentialsHidden)
                    SettingRow(
                      icon: LucideIcons.send,
                      title: 'Test Pushover',
                      subtitle: 'Send a test to your phone.',
                      trailing: SkotiqButton(
                        label: 'Send test',
                        variant: ButtonVariant.secondary,
                        size: ButtonSize.small,
                        isLoading: _activeTest == _NotificationTest.pushover,
                        onPressed: _activeTest == null ? _testPushover : null,
                      ),
                      isLast: true,
                    ),
                ],
              ),
            // The per-event routing matrix and every transport's credentials,
            // on the same page so there is one place for every transport.
            const NotificationRoutingSettings(),
          ],
        );
      },
    );
  }
}

enum _NotificationTest { discord, pushover, push }
