// Provider wiring for the USB / device disconnect log.
//
// The log itself is a plain `UsbDisconnectLog` value object; this file
// supplies the Riverpod plumbing that:
//   1. Instantiates a single log per `ProviderContainer`.
//   2. Subscribes to the backend's event stream and records every
//      `EventCategory.equipment` event whose type is `Disconnected` or
//      `Error` (severity warning or higher).
//   3. Periodically prunes entries older than 24 h so the in-memory
//      list stays bounded for long unattended sessions.
//
// The bridge provider (`usbDisconnectEventBridgeProvider`) MUST be
// `ref.watch`-ed somewhere in the widget tree to stay alive — same
// pattern as `recoveryEventBridgeProvider`. The Run Dashboard
// scaffolding does this so the log is populated as soon as the app
// boots, independent of whether a sequence is running.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/event_types.dart' as core_events;
import '../services/usb_disconnect_log.dart';
import 'backend_provider.dart';

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
/// Side-effecting; produces no state. The Run Dashboard scaffolding
/// watches this so the disconnect history accumulates even when the
/// settings UI / pre-flight dialog hasn't been opened yet.
final usbDisconnectEventBridgeProvider = Provider<void>((ref) {
  final backend = ref.watch(diagnosticsBackendProvider);
  final log = ref.watch(usbDisconnectLogProvider);

  StreamSubscription<core_events.SkotiqEvent>? subscription;
  subscription = backend.eventStream.listen(
    (event) {
      if (event.category != core_events.EventCategory.equipment) return;
      // Only Disconnected/Error events count. PropertyChanged + heartbeat
      // events fire constantly during a connected session and would swamp
      // the log without indicating any disconnect.
      final isDisconnect = event.eventType == 'Disconnected';
      final isError = event.eventType == 'Error';
      if (!isDisconnect && !isError) return;
      // For Error events we additionally require severity >= warning so
      // info-level "device returned ASCOM error" chatter doesn't pollute
      // the count (some drivers raise low-severity errors during a clean
      // shutdown).
      if (isError && event.severity == core_events.EventSeverity.info) {
        return;
      }
      final data = event.data;
      final deviceId = (data['device_id'] as String?) ?? '';
      final deviceType = data['device_type'] as String?;
      final reason =
          (data['message'] as String?) ??
          (data['reason'] as String?) ??
          (isError ? 'device error' : null);
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
