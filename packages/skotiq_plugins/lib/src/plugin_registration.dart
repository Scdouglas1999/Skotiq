// Plugin registration + last-fired activity tracking.
//
// This file glues the user-facing example plugins into the running
// [PluginHost] and surfaces "when did this integration last do something"
// to the Settings > Plugins / Integrations UI.
//
// It deliberately does NOT touch `plugin_host.dart` or `plugin_context.dart`:
// everything here is built on the public host surface
// (`registerPlugin`, `contextFor`, `pluginInfo`) and the public
// `PluginEventBus.on(...)` subscription API. That keeps the host an
// integration-agnostic engine and confines the "which four plugins ship by
// default + which event means each one fired" policy to one file.
//
// Two pieces live here:
//
//   1. [PluginActivityTracker] / [pluginLastFiredProvider] — watches each
//      registered plugin's success event and records the last time it fired.
//
//   2. [PluginEnablementStore] + [pluginEnablementStoreProvider] and
//      [pluginRegistrationProvider] — registers the four example plugins
//      into the host, honouring a persisted enabled-set supplied by an
//      injected store (the app layer / C4 provides the real implementation).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../examples/discord_webhook_plugin.dart';
import '../examples/home_assistant_plugin.dart';
import '../examples/pushover_notification_plugin.dart';
import '../examples/weather_logger_plugin.dart';
import 'plugin_api.dart';
import 'plugin_host.dart';

/// Descriptor for a user-facing example plugin shipped with Skotiq.
///
/// Couples a factory (so each [pluginRegistrationProvider] read can build a
/// fresh, un-shared plugin instance) with the host event the plugin emits on
/// a successful action. [firedEvent] is `null` for plugins that have no
/// discrete "sent / fired" signal (e.g. the weather logger, whose activity is
/// a running reading count rather than a one-shot action).
class ExamplePluginDescriptor {
  /// Stable plugin id, mirrors [SkotiqPlugin.id]. Stored explicitly so
  /// callers can reason about ids (enabled-set lookups, tests) without
  /// constructing a plugin instance first.
  final String id;

  /// Builds a fresh plugin instance. A factory (not a singleton) so the
  /// registration provider can be re-read / re-created after a host dispose
  /// without handing the new host a plugin that already ran its lifecycle
  /// against a dead context.
  final SkotiqPlugin Function() create;

  /// Name of the event the plugin's [PluginContext.eventBus] emits when it
  /// successfully performs its action, or `null` when the plugin has no such
  /// discrete signal.
  final String? firedEvent;

  const ExamplePluginDescriptor({
    required this.id,
    required this.create,
    required this.firedEvent,
  });
}

/// The canonical set of user-facing example plugins Skotiq registers at
/// startup, in registration order.
///
/// Each [ExamplePluginDescriptor.firedEvent] must be the event name the plugin
/// actually passes to `eventBus.emit(...)`, or the activity tracker watches a
/// name nothing emits. The Weather Logger has no discrete success signal —
/// activity is its reading count — so its `firedEvent` is null.
final List<ExamplePluginDescriptor> kUserFacingExamplePlugins =
    List<ExamplePluginDescriptor>.unmodifiable([
      const ExamplePluginDescriptor(
        id: 'com.skotiq.examples.discord_webhook',
        create: DiscordWebhookPlugin.new,
        firedEvent: 'plugin.discord.sent',
      ),
      const ExamplePluginDescriptor(
        id: 'com.skotiq.examples.pushover',
        create: PushoverNotificationPlugin.new,
        firedEvent: 'plugin.pushover.sent',
      ),
      const ExamplePluginDescriptor(
        id: 'com.skotiq.examples.home_assistant',
        create: HomeAssistantPlugin.new,
        firedEvent: 'plugin.home_assistant.service_called',
      ),
      const ExamplePluginDescriptor(
        id: 'com.skotiq.weatherlogger',
        create: WeatherLoggerPlugin.new,
        firedEvent: null,
      ),
    ]);

/// Resolves which plugins should start enabled.
///
/// C3 does not depend on app settings directly. Instead the app layer
/// (C4 / C8) supplies a concrete implementation via
/// [pluginEnablementStoreProvider]. C3 ships only the abstract contract and a
/// safe default ([AllEnabledPluginEnablementStore]) so the package is usable
/// standalone (and in tests) without a settings database.
abstract class PluginEnablementStore {
  /// Whether [pluginId] should be registered in the enabled state.
  ///
  /// Implementations MUST be deterministic for a given persisted state and
  /// MUST NOT throw for unknown ids — return a sensible default instead.
  Future<bool> isEnabled(String pluginId);
}

/// Default enablement policy: every plugin starts enabled.
///
/// This is the behaviour a fresh install wants (the user can then disable
/// integrations they don't use on the Plugins page). The app layer overrides
/// [pluginEnablementStoreProvider] with a settings-backed store that
/// remembers the user's choices.
class AllEnabledPluginEnablementStore implements PluginEnablementStore {
  const AllEnabledPluginEnablementStore();

  @override
  Future<bool> isEnabled(String pluginId) async => true;
}

/// Injection point for the enabled-set policy. Overridden in the app layer
/// (C4/C8) with a settings-backed implementation; defaults to
/// "everything enabled" so the package and its tests work standalone.
final pluginEnablementStoreProvider = Provider<PluginEnablementStore>(
  (ref) => const AllEnabledPluginEnablementStore(),
);

/// Registers the user-facing example plugins into [pluginHostProvider].
///
/// Resolved once (FutureProvider caches its value), but written to be safe to
/// re-read: a plugin that is already registered is treated as success rather
/// than an error, so invalidating + re-reading this provider (e.g. after the
/// enabled-set changes) does not blow up on the `already registered`
/// [PluginException].
///
/// `registerPlugin` itself runs `onLoad` and (when `enabled`) `onEnable`, so a
/// plugin registered with `enabled: false` is loaded but NOT enabled — its
/// `onEnable` is not invoked until the user toggles it on the Plugins page.
final pluginRegistrationProvider = FutureProvider<void>((ref) async {
  final host = ref.watch(pluginHostProvider);
  final store = ref.watch(pluginEnablementStoreProvider);

  await registerPluginDescriptors(
    host: host,
    store: store,
    descriptors: kUserFacingExamplePlugins,
  );
});

/// Register [descriptors] while keeping healthy live instances intact.
///
/// A retained initial-registration failure is explicitly unloaded and rebuilt
/// so invalidating [pluginRegistrationProvider] is a real Retry. Failures are
/// collected until every descriptor has been attempted, preventing one broken
/// integration from silently suppressing all plugins that follow it.
Future<void> registerPluginDescriptors({
  required PluginHost host,
  required PluginEnablementStore store,
  required Iterable<ExamplePluginDescriptor> descriptors,
}) async {
  final failures = <Object>[];

  for (final descriptor in descriptors) {
    // Already registered (e.g. provider re-read after a hot reload or an
    // enabled-set change): leave the live instance untouched. Re-registering
    // would throw, and tearing down + recreating it would discard in-flight
    // plugin state for no benefit.
    if (host.isLoaded(descriptor.id)) {
      if (!host.registrationFailed(descriptor.id)) continue;
      await host.unregisterPlugin(descriptor.id);
    }

    try {
      final enabled = await store.isEnabled(descriptor.id);
      await host.registerPlugin(descriptor.create(), enabled: enabled);
    } catch (error) {
      failures.add(error);
    }
  }

  if (failures.isNotEmpty) {
    throw PluginException(
      '${failures.length} plugin '
      'registration${failures.length == 1 ? '' : 's'} failed',
      failures.first,
    );
  }
}

/// Immutable snapshot of when each registered plugin last fired its success
/// event. Absence of a key means the plugin has not fired since tracking
/// began (or has no discrete fired-event).
typedef PluginLastFired = Map<String, DateTime>;

/// Tracks the last time each plugin emitted its success event.
///
/// One subscription per plugin (well under the sandbox's 32-subscription cap)
/// against the plugin's own [PluginContext.eventBus], obtained from the host
/// via `contextFor`. Subscriptions are torn down on [dispose]; every state
/// mutation is guarded by [_disposed] so a late event delivered after the
/// owning provider is gone never touches disposed state.
class PluginActivityTracker {
  PluginActivityTracker({
    required PluginHost host,
    List<ExamplePluginDescriptor>? descriptors,
    DateTime Function()? now,
  }) : _host = host,
       _descriptors = descriptors ?? kUserFacingExamplePlugins,
       _now = now ?? DateTime.now {
    _subscribe();
  }

  final PluginHost _host;
  final List<ExamplePluginDescriptor> _descriptors;
  final DateTime Function() _now;

  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  final Map<String, DateTime> _lastFired = {};
  final StreamController<PluginLastFired> _controller =
      StreamController<PluginLastFired>.broadcast();

  bool _disposed = false;

  /// Current immutable snapshot of last-fired timestamps.
  PluginLastFired get snapshot => Map.unmodifiable(_lastFired);

  /// Emits a fresh immutable snapshot every time a tracked plugin fires.
  Stream<PluginLastFired> get changes => _controller.stream;

  void _subscribe() {
    for (final descriptor in _descriptors) {
      final firedEvent = descriptor.firedEvent;
      if (firedEvent == null) {
        // No discrete success signal to track (e.g. weather logger).
        continue;
      }

      final context = _host.contextFor(descriptor.id);
      if (context == null) {
        // Plugin not registered (it failed to load, or this tracker was built
        // before registration completed). The activity-tracker provider depends
        // on the registration provider, so a missing context is a wiring bug,
        // not a state to render around.
        throw PluginException(
          'PluginActivityTracker: no context for "${descriptor.id}". '
          'Ensure pluginRegistrationProvider has completed before reading '
          'pluginLastFiredProvider.',
        );
      }

      _subscriptions.add(
        context.eventBus.on(firedEvent).listen((_) {
          _recordFired(descriptor.id);
        }),
      );
    }
  }

  void _recordFired(String pluginId) {
    if (_disposed) return;
    _lastFired[pluginId] = _now();
    if (!_controller.isClosed) {
      _controller.add(Map.unmodifiable(_lastFired));
    }
  }

  /// Cancel all subscriptions and stop emitting snapshots.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _controller.close();
  }
}

/// State-notifier exposing the live last-fired map for the UI.
///
/// Reads the activity tracker (which owns the event subscriptions) and mirrors
/// its snapshots into an immutable [PluginLastFired] map. Every state update is
/// guarded by [mounted] so an event delivered after the provider is disposed
/// is dropped rather than crashing.
class PluginLastFiredNotifier extends StateNotifier<PluginLastFired> {
  PluginLastFiredNotifier(this._tracker) : super(_tracker.snapshot) {
    _subscription = _tracker.changes.listen(_onChanged);
  }

  final PluginActivityTracker _tracker;
  late final StreamSubscription<PluginLastFired> _subscription;

  void _onChanged(PluginLastFired next) {
    if (!mounted) return;
    state = next;
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

/// Owns the [PluginActivityTracker] tied to the current host. Recreated if the
/// host changes; disposed (cancelling its subscriptions) when no longer
/// watched.
///
/// Depends on [pluginRegistrationProvider] so the example plugins are
/// guaranteed loaded — and therefore have a live [PluginContext] —
/// before the tracker tries to subscribe to their events. Reading this before
/// registration finishes is a programming error and surfaces as a thrown
/// [PluginException] (see [PluginActivityTracker]).
final pluginActivityTrackerProvider = Provider<PluginActivityTracker>((ref) {
  // Ensure registration has run. We require() the value so a not-yet-resolved
  // or errored registration surfaces immediately instead of producing a
  // tracker with no plugins to watch.
  ref.watch(pluginRegistrationProvider).requireValue;

  final host = ref.watch(pluginHostProvider);
  final tracker = PluginActivityTracker(host: host);
  ref.onDispose(tracker.dispose);
  return tracker;
});

/// Live "last fired" timestamps per plugin id for the Settings UI.
///
/// Keys are plugin ids; values are the last time that plugin emitted its
/// success event. Plugins that have not fired (or have no discrete success
/// event) are simply absent from the map.
final pluginLastFiredProvider =
    StateNotifierProvider<PluginLastFiredNotifier, PluginLastFired>((ref) {
      final tracker = ref.watch(pluginActivityTrackerProvider);
      return PluginLastFiredNotifier(tracker);
    });
