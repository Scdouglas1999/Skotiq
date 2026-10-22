import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/ffi_backend.dart';
import '../../backend/skotiq_backend.dart';
import '../../models/backend/host_runtime_update.dart';
import '../../services/logging_service.dart';
import '../backend_provider.dart';
import '../host_mutation_event_provider.dart';
import 'runtime_mirror_channel.dart';
import 'runtime_mirror_channels.dart';

const _logSource = 'HostRuntimeMirror';

/// The host's latest value of every runtime channel, served to a client that
/// connects or reconnects (`GET /api/runtime/state`) and stamped with the
/// revision clients order updates by.
class HostRuntimeStateStore {
  final Map<String, HostRuntimeUpdate> _latest = {};
  final Map<String, String> _lastEncoded = {};
  final Map<String, String> _reportOrigins = {};
  int _revision = 0;

  /// Record [value] for [channel]. Returns the update to broadcast, or null
  /// when the value is the same as the one last recorded (a provider can
  /// notify without changing what a client would see).
  HostRuntimeUpdate? record(
    String channel,
    Map<String, dynamic>? value, {
    String? origin,
  }) {
    final encoded = jsonEncode(value);
    if (_lastEncoded[channel] == encoded) return null;
    _lastEncoded[channel] = encoded;
    // Microseconds since the epoch, kept strictly increasing: a client keeps
    // the newest revision it applied, and this stays above it across a host
    // restart.
    final now = DateTime.now().microsecondsSinceEpoch;
    _revision = now > _revision ? now : _revision + 1;
    final update = HostRuntimeUpdate(
      channel: channel,
      revision: _revision,
      value: value,
      origin: origin,
    );
    _latest[channel] = update;
    return update;
  }

  List<HostRuntimeUpdate> snapshot() => List.unmodifiable(_latest.values);

  /// The client whose report is being applied to [channel] right now.
  String? reportOriginFor(String channel) => _reportOrigins[channel];
}

final hostRuntimeStateStoreProvider = Provider<HostRuntimeStateStore>(
  (ref) => HostRuntimeStateStore(),
);

/// Coalesces one channel's changes to at most one publish per [interval],
/// always ending on the newest value.
class _ChannelThrottle {
  _ChannelThrottle(this.interval);

  final Duration interval;
  DateTime? _lastRun;
  Timer? _timer;
  String? _origin;

  void schedule(String? origin, void Function(String? origin) run) {
    // A change from the host itself after a client's report means the value
    // is no longer that client's.
    _origin = _timer == null ? origin : (origin == _origin ? origin : null);
    final last = _lastRun;
    final now = DateTime.now();
    if (interval == Duration.zero ||
        last == null ||
        now.difference(last) >= interval) {
      _timer?.cancel();
      _timer = null;
      _lastRun = now;
      run(_origin);
      return;
    }
    _timer ??= Timer(interval - now.difference(last), () {
      _timer = null;
      _lastRun = DateTime.now();
      run(_origin);
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Publishes the host's runtime channels to linked clients.
///
/// Runs on a process that owns the hardware ([FfiBackend]). Every change of a
/// channel's provider is recorded in [hostRuntimeStateStoreProvider] and, when
/// the embedded API server is up, broadcast on `/events` as a
/// [hostRuntimeStateEventType] event. Without a server the broadcast is a
/// no-op and only the store is kept, so a server started later serves current
/// values to its first client.
final hostRuntimeMirrorProvider = Provider<void>((ref) {
  final subscriptions = <ProviderSubscription<Object?>>[];
  final throttles = <String, _ChannelThrottle>{};

  void teardown() {
    for (final sub in subscriptions) {
      sub.close();
    }
    subscriptions.clear();
    for (final throttle in throttles.values) {
      throttle.cancel();
    }
    throttles.clear();
  }

  ref.onDispose(teardown);

  void publish(RuntimeMirrorChannel<Object?> channel, String? origin) {
    final store = ref.read(hostRuntimeStateStoreProvider);
    final Map<String, dynamic>? value;
    try {
      value = channel.encodeCurrent(ref);
    } catch (e, st) {
      ref
          .read(loggingServiceProvider)
          .warning(
            'Runtime channel ${channel.key} could not be encoded: $e',
            source: _logSource,
            fields: {'stackTrace': '$st'},
          );
      return;
    }
    final update = store.record(channel.key, value, origin: origin);
    if (update == null) return;
    ref.read(hostMutationEventHubProvider).broadcastRemote(update.toEvent());
  }

  void bind() {
    teardown();
    if (ref.read(backendProvider) is! FfiBackend) return;
    final store = ref.read(hostRuntimeStateStoreProvider);
    for (final channel in ref.read(runtimeMirrorChannelsProvider)) {
      final throttle = throttles[channel.key] = _ChannelThrottle(
        channel.minInterval,
      );
      subscriptions.add(
        channel.listen(ref, (_) {
          throttle.schedule(
            store.reportOriginFor(channel.key),
            (origin) => publish(channel, origin),
          );
        }),
      );
      publish(channel, null);
    }
  }

  ref.listen<SkotiqBackend>(backendProvider, (_, __) => bind());
  bind();
});

/// Apply a linked client's report of a [RuntimeMirrorChannel.clientReports]
/// channel to the host's own providers. The host GUI then shows the client's
/// result, and the resulting broadcast names [origin] so the reporting client
/// does not apply it again. Returns false for an unknown or host-only channel.
bool applyClientRuntimeReport(
  ProviderContainer container, {
  required String channel,
  required Map<String, dynamic>? value,
  required String origin,
}) {
  final target = runtimeChannelFor(
    container.read(runtimeMirrorChannelsProvider),
    channel,
  );
  if (target == null || !target.clientReports) return false;
  // Make sure the publisher is listening, so the report reaches other clients.
  container.read(hostRuntimeMirrorProvider);
  final store = container.read(hostRuntimeStateStoreProvider);
  store._reportOrigins[channel] = origin;
  try {
    target.apply(RuntimeApplyContext(container), value);
  } on FormatException catch (e) {
    container
        .read(loggingServiceProvider)
        .warning(
          'Runtime report $channel from $origin dropped: ${e.message}',
          source: _logSource,
        );
  } finally {
    store._reportOrigins.remove(channel);
  }
  return true;
}
