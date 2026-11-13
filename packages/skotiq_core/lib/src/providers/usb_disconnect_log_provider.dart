// Provider wiring for the USB / device disconnect log.
//
// The log itself is a plain `UsbDisconnectLog` value object; this file
// supplies the Riverpod plumbing that:
//   1. Instantiates a single log per `ProviderContainer`.
//   2. Subscribes to the backend's event stream and records every
//      `EventCategory.equipment` `Error` event of severity warning or
//      higher. That is how a lost device arrives: the heartbeat gives it up
//      and publishes an Error with the reason. A `Disconnected` event is
//      not recorded: the native side publishes it only from its disconnect
//      command (the Disconnect button, a profile switch, shutdown), which is
//      the operator's doing, not a dropout.
//   3. Periodically prunes entries older than 24 h so the in-memory
//      list stays bounded for long unattended sessions.
//
// The bridge provider (`usbDisconnectEventBridgeProvider`) is an always-on
// service: it is started at launch from the table in
// `skotiq_app/startup/always_on_services.dart`, so the log fills from the
// moment the app is up, whether or not a sequence is running.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/event_types.dart' as core_events;
import '../services/usb_disconnect_log.dart';
import 'backend_provider.dart';
import 'logging_service_provider.dart';

/// Singleton log per provider container.
///
/// The default lifetime is the container lifetime. Tests override this
/// to inject a deterministic-clock log without rebuilding the full
/// container hierarchy.
final usbDisconnectLogProvider = Provider<UsbDisconnectLog>((ref) {
  return UsbDisconnectLog();
});

/// Bridge that listens to the backend's event stream and feeds the log.
///
/// Side-effecting; produces no state. Started at launch as an always-on
/// service, so the history accumulates before any screen asks for it.
final usbDisconnectEventBridgeProvider = Provider<void>((ref) {
  final backend = ref.watch(diagnosticsBackendProvider);
  final log = ref.watch(usbDisconnectLogProvider);

  StreamSubscription<core_events.SkotiqEvent>? subscription;
  subscription = backend.eventStream.listen(
    (event) {
      if (event.category != core_events.EventCategory.equipment) return;
      if (event.eventType != 'Error') return;
      // Severity >= warning, so info-level "device returned ASCOM error"
      // chatter doesn't pollute the count (some drivers raise low-severity
      // errors during a clean shutdown).
      if (event.severity == core_events.EventSeverity.info) return;
      final data = event.data;
      final deviceId = (data['device_id'] as String?) ?? '';
      final deviceType = data['device_type'] as String?;
      final reason =
          (data['message'] as String?) ??
          (data['reason'] as String?) ??
          'device error';
      // We use the wall-clock at receive time rather than the event's
      // own timestamp because the event timestamp on `SkotiqEvent`
      // is `millisecondsSinceEpoch` and we'd just convert it; using
      // DateTime.now() avoids a precision-loss round-trip and matches
      // the existing log entries when called manually.
      log.recordDisconnect(
        deviceId: deviceId,
        deviceType: deviceType,
        reason: reason,
      );
      ref
          .read(loggingServiceProvider)
          .warning(
            'Device error recorded',
            source: 'UsbDisconnectLog',
            fields: {
              'device': deviceId,
              if (deviceType != null) 'type': deviceType,
              'reason': reason,
            },
          );
    },
    onError: (Object error) {
      // Log-only — a stream error must not block subsequent events.
      developer.log(
        '[UsbDisconnectEventBridge] Event stream error: $error',
        name: 'UsbDisconnectEventBridge',
        level: 1000,
        error: error,
      );
    },
  );

  // Periodic prune — 5 minutes is generous because the read paths
  // already prune on demand. This only matters for very long unattended
  // sessions that never query the log.
  final pruneTimer = Timer.periodic(
    const Duration(minutes: 5),
    (_) => log.prune(),
  );

  ref.onDispose(() {
    subscription?.cancel();
    pruneTimer.cancel();
  });
});
