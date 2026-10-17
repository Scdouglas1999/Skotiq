import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../../services/push_delivery_targets_provider.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/tutorial_keys/settings_keys.dart';
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
  return '$reason — critical alerts will only appear in the app '
      'while it is open on your network.';
}

/// Subtitle for one of the three built-in event switches.
///
/// The three settings are live, not decorative: `NotificationService.notify`
/// refuses the entire dispatch for an event family whose flag is off (see
/// `_shouldNotifyForEvent`), so with one off that family plays no alert sound,
/// posts nothing in-app and sends nothing to the Discord/Pushover webhook this
/// page configures. Per-event routing runs off its own matrix and is
/// unaffected either way.
///
/// [sends] names what the family covers. [offByDefault] is true for meridian
/// flip alone, whose stored default is `false` — the one row where a switch
/// sitting at off is Skotiq's choice rather than the operator's, which is
/// exactly what an operator expecting a flip alert has to be told.
String builtInEventAlertSubtitle(
  String sends, {
  required bool enabled,
  bool offByDefault = false,
}) {
  if (enabled) {
    return '$sends Delivered by the alert sound, the in-app feed, and the '
        'Discord/Pushover webhook configured on this page.';
  }
  return offByDefault
      ? '$sends Off — and off is the shipped default, so no flip alert is sent '
          'until you turn this on.'
      : '$sends Off — this event family sends nothing.';
}

class NotificationSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const NotificationSettings({super.key, this.isMobile = false});

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
      final notificationService = ref.read(notificationServiceProvider);
      final success = await notificationService.testDiscordWebhook(webhook);
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
      final notificationService = ref.read(notificationServiceProvider);
      final success = await notificationService.testPushover(key, user);
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
          'Test queued to the active push transport. Cloud delivery requires '
          'FCM/APNs credentials and a registered mobile token.',
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
      identical(ref.read(backendProvider), authority);

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final authority = ref.watch(backendProvider);
    final isRemoteController = authority is NetworkBackend;
    final AsyncValue<PushNotificationConfig>? pushConfigAsync =
        isRemoteController ? null : ref.watch(pushNotificationConfigProvider);
    // Real delivery state, so the critical-alert row can stop asserting a
    // capability the system may not have.
    final pushTargetsAsync = ref.watch(pushDeliveryTargetsProvider);
    final pushTargets =
        pushTargetsAsync.valueOrNull ?? PushDeliveryTargets.none;

    return settingsAsync.when(
      loading: () => SettingsLoadingState(
        isMobile: widget.isMobile,
      ),
      error: (error, stack) => SettingsErrorState(
        isMobile: widget.isMobile,
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
          key: SettingsTutorialKeys.notifications,
          title: 'Notifications',
          description: 'Configure alerts and notifications',
          children: [
            SettingsSection(
              title: 'General',
              children: [
                SettingRow(
                  icon: LucideIcons.bell,
                  title: 'Enable notifications',
                  subtitle: 'Send notifications for important events',
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
                  title: 'Sound alerts',
                  subtitle: 'Play sounds for notifications',
                  trailing: SettingsSwitch(
                    value: settings.soundEnabled,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setSoundEnabled(value);
                    },
                  ),
                  isLast: true,
                ),
              ],
            ),
            // Three sets of near-identically named controls cover "a sequence
            // finished" on this one leaf, and nothing told the operator which
            // of them decides whether their phone buzzes. Say it once, at the
            // top, before any of the switches.
            const SettingsSection(
              title: 'Which of these decides where an alert goes',
              children: [
                SettingRow(
                  icon: LucideIcons.share2,
                  title: 'Per-event routing is the live one',
                  subtitle:
                      'Per-event routing (Settings → Notification Routing) '
                      'maps each event to its transports and is what actually '
                      'delivers. Push to Mobile below is the separate host '
                      'push gate; neither overrides the other, so an event '
                      'enabled in both is sent by both. The switches under '
                      '"Built-in event alerts" are a third, older path: they '
                      'gate Skotiq\'s own alert sound, in-app post and '
                      'Discord/Pushover webhook for those three event '
                      'families only.',
                  trailing: SizedBox.shrink(),
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Built-in event alerts',
              children: [
                SettingRow(
                  icon: LucideIcons.checkCircle,
                  title: 'Sequence complete',
                  subtitle: builtInEventAlertSubtitle(
                    "Gates Skotiq's built-in sequence-complete alert.",
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
                    'Gates the built-in error alert, raised by capture '
                    'failures and device-reconnect failures.',
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
                    'Gates the built-in meridian-flip alert, raised when the '
                    'flip monitor starts and finishes a flip.',
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
            // Critical-event escalation: audible alert + cross-platform
            // push so the user walking away from the laptop / out to the
            // scope still gets a hard, attention-grabbing alert on a fail.
            SettingsSection(
              title: 'Critical events (unattended imaging)',
              children: [
                SettingRow(
                  icon: LucideIcons.bellRing,
                  title: 'Audible alert on critical events',
                  subtitle: 'Play the system bell when a critical error fires',
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
                  title: 'Alert sound',
                  subtitle: 'Which sound to play when critical events fire',
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
                  title: 'Push critical alerts to mobile',
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
                title: 'Push to mobile',
                children: [
                  SettingRow(
                    icon: LucideIcons.server,
                    title: 'Configure push on the Skotiq host',
                    subtitle: 'The master push gate and event toggles are '
                        'host-owned. This controller will not edit an '
                        'unrelated local copy.',
                    trailing: SizedBox.shrink(),
                    isLast: true,
                  ),
                ],
              )
            else if (pushConfigAsync!.isLoading)
              SettingsSection(
                title: 'Push to mobile',
                children: [
                  SettingRow(
                    icon: LucideIcons.smartphone,
                    title: 'Loading push configuration…',
                    subtitle: 'Push controls will be available when the '
                        'saved configuration has loaded.',
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
                title: 'Push to mobile',
                children: [
                  SettingRow(
                    icon: LucideIcons.alertTriangle,
                    title: 'Could not load push configuration',
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
                title: 'Push to mobile',
                children: [
                  SettingRow(
                    icon: LucideIcons.smartphone,
                    title: 'Enable push to mobile',
                    subtitle: 'Send alerts to connected mobile devices',
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
                    subtitle: 'Push when sequence finishes',
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
                    subtitle: 'Push on sequence errors or stops',
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
                    subtitle: 'Push on meridian flip events',
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
                    subtitle: 'Push when safety monitor reports unsafe',
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
                    subtitle: 'Push when guide star is lost',
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
                    subtitle: 'Push when camera exposure fails',
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
                    subtitle: 'Push when autofocus fails',
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
                    subtitle: 'Push when a device disconnects',
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
                    title: 'Test push notification',
                    subtitle:
                        'Queue a test to the active transport (host logs report cloud failures)',
                    trailing: SkotiqButton(
                      label: 'Test',
                      variant: ButtonVariant.primary,
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
            // Legacy `app_settings`-backed Discord/Pushover credentials. They
            // are shown ONLY on a remote controller: locally the keyring-backed
            // sections inside NotificationRoutingSettings below are the single
            // Discord/Pushover configuration on this page (they adopt and keep
            // these same legacy keys in step, so the pre-router
            // NotificationService keeps sending to whatever is on screen).
            // Rendering both locally is what let one half of the page report
            // "unconfigured" while the other half held a saved webhook.
            // A remote controller cannot reach the host's keyring, so there the
            // legacy keys — which ride the settings remote-sync to the host —
            // remain the only way to configure these two transports.
            if (isRemoteController)
              SettingsSection(
                title: 'Discord',
                children: [
                  SettingRow(
                    icon: LucideIcons.messageSquare,
                    title: 'Webhook URL',
                    subtitle: 'Discord channel webhook for notifications',
                    trailing: settingsTrailingTextInput(
                      context: context,
                      controller: _discordController,
                      authoritativeValue: settings.discordWebhook,
                      authorityKey: authority,
                      hint: 'https://discord.com/api/webhooks/...',
                      isMobile: widget.isMobile,
                      obscure: true,
                      onChanged: (value) {
                        return ref
                            .read(appSettingsProvider.notifier)
                            .setDiscordWebhook(value);
                      },
                    ),
                  ),
                  SettingRow(
                    icon: LucideIcons.send,
                    title: 'Test Discord',
                    subtitle:
                        'Send a test notification to your Discord channel',
                    trailing: SkotiqButton(
                      label: 'Test',
                      variant: ButtonVariant.primary,
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
                    subtitle: 'Pushover application API key',
                    trailing: SettingsTextInput(
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
                  SettingRow(
                    icon: LucideIcons.user,
                    title: 'User key',
                    subtitle: 'Pushover user/group key',
                    trailing: SettingsTextInput(
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
                  SettingRow(
                    icon: LucideIcons.send,
                    title: 'Test Pushover',
                    subtitle: 'Send a test notification to your device',
                    trailing: SkotiqButton(
                      label: 'Test',
                      variant: ButtonVariant.primary,
                      size: ButtonSize.small,
                      isLoading: _activeTest == _NotificationTest.pushover,
                      onPressed: _activeTest == null ? _testPushover : null,
                    ),
                    isLast: true,
                  ),
                ],
              ),
            // Comprehensive per-event routing matrix + every transport's
            // credentials, including the only local Discord / Pushover
            // configuration. Lives inside the same Notifications page so users
            // see one place for every transport.
            NotificationRoutingSettings(
              isMobile: widget.isMobile,
            ),
          ],
        );
      },
    );
  }
}

enum _NotificationTest { discord, pushover, push }
