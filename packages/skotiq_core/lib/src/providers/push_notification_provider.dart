import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/network_backend.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import '../services/push_notification_service.dart';

/// Notifier that manages push notification configuration, persisted to database
class PushNotificationConfigNotifier
    extends AsyncNotifier<PushNotificationConfig> {
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<PushNotificationConfig> build() async {
    final dao = ref.read(settingsDaoProvider);
    final json = await dao.getSetting('push_notification_config');
    if (json != null) {
      try {
        final map = jsonDecode(json) as Map<String, dynamic>;
        return PushNotificationConfig(
          enabled: map['enabled'] as bool? ?? true,
          notifySequenceCompleted:
              map['notifySequenceCompleted'] as bool? ?? true,
          notifySequenceFailed: map['notifySequenceFailed'] as bool? ?? true,
          notifyMeridianFlip: map['notifyMeridianFlip'] as bool? ?? true,
          notifyWeatherUnsafe: map['notifyWeatherUnsafe'] as bool? ?? true,
          notifyGuidingLost: map['notifyGuidingLost'] as bool? ?? true,
          notifyExposureFailed: map['notifyExposureFailed'] as bool? ?? true,
          notifyAutofocusFailed: map['notifyAutofocusFailed'] as bool? ?? true,
          notifyEquipmentDisconnected:
              map['notifyEquipmentDisconnected'] as bool? ?? false,
        );
      } catch (e, stackTrace) {
        developer.log(
          '[PushNotificationConfig] Failed to parse config: $e',
          name: 'PushNotificationConfig',
          level: 1000,
          error: e,
          stackTrace: stackTrace,
        );
        Error.throwWithStackTrace(
          StateError('Push notification configuration is corrupt: $e'),
          stackTrace,
        );
      }
    }
    return const PushNotificationConfig();
  }

  Future<void> _persist(PushNotificationConfig config) async {
    final dao = ref.read(settingsDaoProvider);
    final json = jsonEncode({
      'enabled': config.enabled,
      'notifySequenceCompleted': config.notifySequenceCompleted,
      'notifySequenceFailed': config.notifySequenceFailed,
      'notifyMeridianFlip': config.notifyMeridianFlip,
      'notifyWeatherUnsafe': config.notifyWeatherUnsafe,
      'notifyGuidingLost': config.notifyGuidingLost,
      'notifyExposureFailed': config.notifyExposureFailed,
      'notifyAutofocusFailed': config.notifyAutofocusFailed,
      'notifyEquipmentDisconnected': config.notifyEquipmentDisconnected,
    });
    await dao.setSetting('push_notification_config', json);
    if (!identical(ref.read(settingsDaoProvider), dao)) {
      throw StateError(
        'The settings database changed while saving push notifications.',
      );
    }
  }

  Future<void> _update(
    PushNotificationConfig Function(PushNotificationConfig current) change,
  ) {
    final operation = _writeTail.then((_) async {
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError(
          'Push notification configuration is not loaded; refusing to '
          'overwrite it with defaults.',
        );
      }
      final updated = change(current);
      await _persist(updated);
      state = AsyncData(updated);
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> setEnabled(bool value) =>
      _update((current) => current.copyWith(enabled: value));

  Future<void> setNotifySequenceCompleted(bool value) =>
      _update((current) => current.copyWith(notifySequenceCompleted: value));

  Future<void> setNotifySequenceFailed(bool value) =>
      _update((current) => current.copyWith(notifySequenceFailed: value));

  Future<void> setNotifyMeridianFlip(bool value) =>
      _update((current) => current.copyWith(notifyMeridianFlip: value));

  Future<void> setNotifyWeatherUnsafe(bool value) =>
      _update((current) => current.copyWith(notifyWeatherUnsafe: value));

  Future<void> setNotifyGuidingLost(bool value) =>
      _update((current) => current.copyWith(notifyGuidingLost: value));

  Future<void> setNotifyExposureFailed(bool value) =>
      _update((current) => current.copyWith(notifyExposureFailed: value));

  Future<void> setNotifyAutofocusFailed(bool value) =>
      _update((current) => current.copyWith(notifyAutofocusFailed: value));

  Future<void> setNotifyEquipmentDisconnected(bool value) => _update(
    (current) => current.copyWith(notifyEquipmentDisconnected: value),
  );
}

/// Provider for push notification config (persisted)
final pushNotificationConfigProvider =
    AsyncNotifierProvider<
      PushNotificationConfigNotifier,
      PushNotificationConfig
    >(PushNotificationConfigNotifier.new);

/// Fail-closed push config: the master `enabled` gate is off, so
/// [PushNotificationService.enqueue] swallows every phone push. This is the
/// broadcaster's initial config until [pushNotificationConfigProvider] yields
/// authoritative data, and it is re-applied whenever that provider errors so a
/// corrupt or unavailable config can never leave the phone-push feed
/// broadcasting against a manufactured (enabled-by-default) config.
const PushNotificationConfig _failClosedPushConfig = PushNotificationConfig(
  enabled: false,
);

/// Provider for the PushNotificationService instance.
///
/// A pure mobile-push *broadcaster*: it does not subscribe to the backend
/// event stream or classify events. The [NotificationRouter]'s
/// [SystemPushTransport] is the single producer of mobile pushes and calls
/// `enqueue` here; the service's stream is consumed by the embedded web server
/// to broadcast to connected mobile WebSocket clients.
///
/// The [PushNotificationConfig] remains the one config store for the
/// systemPush feed (its per-event toggles + master `enabled` gate are read by
/// [SystemPushTransport] / enforced in `enqueue`); config changes are applied
/// in-place via [PushNotificationService.updateConfig].
///
/// Fail-closed authority: the service starts DISABLED and only enables once the
/// config provider hands back authoritative data. During DB loading, a corrupt
/// blob, or a failed refresh after a prior success, the config is unavailable —
/// the broadcaster stays (or returns to) disabled so events cannot broadcast to
/// paired phones against defaults the user never persisted.
final pushNotificationServiceProvider = Provider<PushNotificationService>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    // A controller neither serves paired phones nor owns the host's push
    // configuration. Keep its broadcaster inert and do not initialize an
    // unrelated controller-side config authority merely because the shared
    // app shell eagerly watches this provider.
    final service = PushNotificationService(config: _failClosedPushConfig);
    ref.onDispose(service.dispose);
    return service;
  }

  // Read (don't watch) config for initial value -- changes are handled via
  // ref.listen below so the broadcaster instance (and the web server's
  // subscription to its stream) survives a config toggle. Seed fail-closed
  // unless the config is ALREADY authoritative at construction time.
  final configAsync = ref.read(pushNotificationConfigProvider);
  final service = PushNotificationService(
    config: configAsync.valueOrNull ?? _failClosedPushConfig,
  );

  ref.listen<AsyncValue<PushNotificationConfig>>(
    pushNotificationConfigProvider,
    (previous, next) {
      // Fail-closed on any error, including a failed refresh after a prior
      // success: disable immediately rather than retaining the last enabled
      // config. Checked before `valueOrNull` because an AsyncError produced
      // from a reload can still carry the previous value.
      if (next.hasError) {
        service.updateConfig(_failClosedPushConfig);
        return;
      }
      final newConfig = next.valueOrNull;
      if (newConfig != null) {
        service.updateConfig(newConfig);
      }
      // AsyncLoading with no value yet: leave the service as-is. The initial
      // build already seeded fail-closed, and a mid-flight reload keeps the
      // last authoritative value until it resolves.
    },
  );

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});
