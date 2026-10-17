// Hot-plug discovery event bridge.
//
// The Rust hot-plug watcher in `native/skotiq_native/bridge/src/hotplug.rs`
// polls the native (vendor SDK) and ASCOM (Windows only) device lists and
// publishes one `EquipmentEvent::DeviceDiscovered` per arrival or
// `EquipmentEvent::DeviceLost` per removal — first-class typed FRB variants
// the FFI layer maps to the 'DeviceDiscovered' / 'DeviceLost' event types.
// Linux/macOS additionally get fine-grained libusb hot-plug callbacks;
// Windows gets WM_DEVICECHANGE notifications; all three paths emit through the
// same Equipment event channel.
//
// This bridge listens on `backend.eventStream` for those events and
// invalidates the equipment-discovery Riverpod providers
// (`availableCamerasProvider`, `availableMountsProvider`, ...,
// `unifiedDiscoveryProvider`) so the equipment screen refreshes inside
// the configured ~3 s budget without any user-driven pull-to-refresh.
//
// The bridge is side-effecting and produces no state. To stay alive, the
// surrounding app must `ref.watch(hotplugEventBridgeProvider)` somewhere
// in its bootstrap (the desktop/mobile dashboard scaffolding does this
// alongside the other event bridges).

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/event_types.dart' as core_events;
import '../services/device_service.dart';
import 'backend_provider.dart';
import 'unified_discovery_provider.dart';

/// Bridge that watches the backend event stream for hot-plug arrivals /
/// removals and invalidates the per-class discovery providers so the next
/// UI read re-runs the underlying scan.
///
/// Producing no state, this provider is bound to its container lifetime;
/// reading it once (via `ref.watch` from a long-lived widget) is enough to
/// keep the subscription alive.
final hotplugEventBridgeProvider = Provider<void>((ref) {
  final backend = ref.watch(diagnosticsBackendProvider);

  // Coalesce bursts. A single physical action can emit many hot-plug events in
  // one event-loop turn: a powered USB hub registers every downstream device
  // at once, and the 4 s Rust poll batches all arrivals/removals discovered in
  // a cycle into back-to-back PropertyChanged events. Invalidating all ten
  // per-class discovery FutureProviders *per event* turns N arrivals into 10×N
  // device-list scans queued in the same turn — an O(N) amplification of the
  // device-event→UI path. We instead buffer qualifying events and flush a
  // single invalidation round on a short debounce, so a burst of any size
  // costs exactly one scan round. The refresh still lands well inside the
  // ~3 s budget. (errors-are-a-feature: no event is dropped — the first
  // qualifying event in a window still guarantees a refresh; we only collapse
  // the *count* of redundant invalidations.)
  const coalesceWindow = Duration(milliseconds: 150);
  Timer? flushTimer;

  void flushInvalidations() {
    // Invalidate every per-class discovery provider so the next read re-runs
    // the scan. We invalidate the full set rather than trying to pick the
    // matching class because a single hot-plug event can affect multiple lists
    // (a USB-Serial bridge that registers both a mount and a focuser, an OAG
    // that exposes both a camera and a filter wheel, etc.).
    ref.invalidate(availableCamerasProvider);
    ref.invalidate(availableMountsProvider);
    ref.invalidate(availableFocusersProvider);
    ref.invalidate(availableFilterWheelsProvider);
    ref.invalidate(availableRotatorsProvider);
    ref.invalidate(availableGuidersProvider);
    ref.invalidate(availableDomesProvider);
    ref.invalidate(availableWeatherProvider);
    ref.invalidate(availableSafetyMonitorsProvider);
    ref.invalidate(availableSwitchesProvider);

    // The unified discovery state is a StateNotifier — invalidating it would
    // lose the in-progress scan, which is the wrong behaviour when an arrival
    // lands during a manual rescan. Instead, re-read the notifier and let its
    // next discover call pull the fresh vendor-SDK list. We deliberately do NOT
    // trigger a `discoverAll` from here: that would saturate the LAN if the
    // polling watcher batches arrivals (e.g. plugging in a powered USB hub).
    // The per-class FutureProvider invalidations above are enough to refresh
    // the equipment screen's primary lists.
    try {
      ref.read(unifiedDiscoveryProvider.notifier);
    } catch (_) {
      // Provider not yet read by any UI — nothing to do, the next read will
      // see the invalidated per-class FutureProviders.
    }
  }

  StreamSubscription<core_events.SkotiqEvent>? subscription;
  subscription = backend.eventStream.listen(
    (event) {
      if (event.category != core_events.EventCategory.equipment) return;
      // The hot-plug watcher emits first-class `DeviceDiscovered` /
      // `DeviceLost` typed variants, so a simple eventType filter is enough —
      // no need to inspect a JSON payload to distinguish hot-plug events from
      // the unrelated (and frequent) Mount / Camera / Focuser property-changed
      // traffic.
      if (event.eventType != core_events.deviceDiscoveredEventType &&
          event.eventType != core_events.deviceLostEventType) {
        return;
      }

      developer.log(
        '[HotplugEventBridge] ${event.eventType}: ${event.data['id']}',
        name: 'HotplugEventBridge',
        level: 800,
      );

      // Debounce: (re)arm the flush timer. A burst of qualifying events in the
      // same window collapses to a single invalidation round when the timer
      // fires, rather than one round per event.
      flushTimer?.cancel();
      flushTimer = Timer(coalesceWindow, flushInvalidations);
    },
    onError: (Object error) {
      developer.log(
        '[HotplugEventBridge] Event stream error: $error',
        name: 'HotplugEventBridge',
        level: 1000,
        error: error,
      );
    },
  );

  ref.onDispose(() {
    flushTimer?.cancel();
    subscription?.cancel();
  });
});
