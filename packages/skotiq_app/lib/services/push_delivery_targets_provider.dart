/// Truthful "can a critical alert actually reach a phone?" state for the
/// notification settings surface.
///
/// The "Push critical alerts to mobile" row used to render as a plain ON
/// switch whatever the real delivery state was. On Android that claim was
/// never true in a stock build — the FCM client is a dormant scaffold pending
/// Firebase provisioning (`apps/mobile/android/app/google-services.json` is
/// absent), so the phone logs
/// `FCM not configured (no google-services.json); push registration dormant`
/// and never registers a token. The switch therefore asserted a capability the
/// system did not have.
///
/// Two authorities answer the question, depending on where this code runs:
///   * a remote controller (phone/tablet paired to a host) asks the host over
///     `GET /api/push/targets` — its own local pairing DB knows nothing about
///     who has registered with the host;
///   * the host itself reads the same `PairingDatabase` its headless server
///     writes push tokens into, plus the on-disk `push_config.json` that
///     decides whether a cloud channel exists at all.
library;

import 'dart:developer' as developer;

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// The pairing database the host's headless server stores push tokens in.
///
/// A separate Drift connection to the same file the server uses — the same
/// thing `PairingNotifier` already does for the paired-device list. Overridable
/// so tests can supply an in-memory database.
final pushPairingDatabaseProvider = Provider<PairingDatabase>((ref) {
  final db = PairingDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Whether the HOST has a cloud push channel configured. Overridable in tests.
final hostCloudPushConfiguredProvider = FutureProvider<bool>((ref) async {
  try {
    final dir = await resolveSkotiqDataDirectory();
    final config = await PushConfig.load(appSupportDir: dir.path);
    return config.hasCloudChannel || config.mock;
  } on MissingPluginException {
    // No platform channel (widget tests / headless harness) — we cannot claim
    // a channel exists.
    return false;
  } catch (e) {
    // Reporting "no cloud channel" is the fail-closed answer and stays. But an
    // unreadable/corrupt push_config.json presents identically to a genuinely
    // unconfigured host, so the operator would be told push is not set up when
    // it is. The log is the only place that distinction survives.
    developer.log(
      'Could not read the host push configuration; reporting no cloud channel: '
      '$e',
      name: 'PushDeliveryTargets',
      level: 900,
    );
    return false;
  }
});

/// Whether a critical alert could actually be delivered to a phone right now.
///
/// Never throws: a host that cannot be reached is reported as "cannot
/// deliver", which is the honest answer — an alert really would not arrive.
final pushDeliveryTargetsProvider = FutureProvider<PushDeliveryTargets>((
  ref,
) async {
  final backend = ref.watch(backendProvider);

  if (backend is DisconnectedBackend) {
    return PushDeliveryTargets.none;
  }

  if (backend is NetworkBackend) {
    try {
      return await backend.getPushDeliveryTargets();
    } catch (e) {
      // An unreachable/older host cannot be shown as "delivery works".
      // Logged because "host unreachable" and "host has no push targets"
      // render identically in settings, and only the first is actionable.
      developer.log(
        'Could not query push delivery targets from the host; reporting no '
        'delivery targets: $e',
        name: 'PushDeliveryTargets',
        level: 900,
      );
      return PushDeliveryTargets.none;
    }
  }

  // Local host.
  try {
    final db = ref.watch(pushPairingDatabaseProvider);
    final tokens = await db.getAllPushTokens();
    final deviceIds = <String>{};
    var fcm = 0;
    var apns = 0;
    for (final token in tokens) {
      deviceIds.add(token.deviceId);
      switch (token.platform) {
        case 'fcm':
          fcm++;
        case 'apns':
          apns++;
      }
    }
    final cloudConfigured =
        await ref.watch(hostCloudPushConfiguredProvider.future);
    return PushDeliveryTargets(
      registeredDeviceCount: deviceIds.length,
      fcmTokenCount: fcm,
      apnsTokenCount: apns,
      cloudDeliveryConfigured: cloudConfigured,
    );
  } catch (e) {
    // Same reasoning as the remote branch: a failed pairing-database read must
    // not be presented as "no phones registered", which is what the settings
    // row would otherwise say about a rig that does have devices paired.
    developer.log(
      'Could not read locally registered push tokens; reporting no delivery '
      'targets: $e',
      name: 'PushDeliveryTargets',
      level: 900,
    );
    return PushDeliveryTargets.none;
  }
});
