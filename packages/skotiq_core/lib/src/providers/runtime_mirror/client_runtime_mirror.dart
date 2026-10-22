import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../backend/skotiq_backend.dart';
import '../../models/backend/host_runtime_update.dart';
import '../../services/logging_service.dart';
import '../backend_provider.dart';
import '../provider_reader.dart';
import 'runtime_mirror_channel.dart';
import 'runtime_mirror_channels.dart';

const _logSource = 'ClientRuntimeMirror';

/// Identifies this process in its runtime reports, so the host's broadcast of
/// a value this client reported is not applied here a second time.
final String runtimeMirrorOrigin = _newOrigin();

String _newOrigin() {
  final random = Random.secure();
  return List.generate(
    12,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// What this client last applied from the host, per channel.
class ClientRuntimeMirrorState {
  final Map<String, int> _revisions = {};
  final Map<String, Object?> _applied = {};
  final Set<String> _applying = {};

  /// The provider value the last host update produced, so the reporter can
  /// tell a host value from one this client computed.
  Object? appliedValue(String channel) => _applied[channel];

  bool hasApplied(String channel) => _applied.containsKey(channel);

  /// True while a host update is being written into [channel]'s provider.
  bool isApplying(String channel) => _applying.contains(channel);

  void reset() {
    _revisions.clear();
    _applied.clear();
  }
}

final clientRuntimeMirrorStateProvider = Provider<ClientRuntimeMirrorState>(
  (ref) => ClientRuntimeMirrorState(),
);

/// Apply one runtime update from the host to this client's providers.
///
/// Updates older than the one already applied for the channel are dropped (an
/// event can race the hydration fetch), as are updates this client reported.
void applyHostRuntimeUpdate(
  Object reader,
  HostRuntimeUpdate update, {
  required NetworkBackend networkBackend,
}) {
  final channel = runtimeChannelFor(
    readProvider(reader, runtimeMirrorChannelsProvider),
    update.channel,
  );
  if (channel == null) return;
  final state = readProvider(reader, clientRuntimeMirrorStateProvider);
  final last = state._revisions[update.channel];
  if (last != null && update.revision <= last) return;
  state._revisions[update.channel] = update.revision;
  if (update.origin == runtimeMirrorOrigin) return;
  state._applying.add(update.channel);
  try {
    channel.apply(
      RuntimeApplyContext(reader, networkBackend: networkBackend),
      update.value,
    );
  } on FormatException catch (e) {
    developer.log(
      'Runtime update ${update.channel} dropped: ${e.message}',
      name: _logSource,
      level: 900,
    );
  } finally {
    state._applying.remove(update.channel);
  }
  state._applied[update.channel] = channel.readSource(reader);
}

/// Fill every runtime channel from the host's current values. Runs on connect,
/// on reconnect and with the periodic re-hydrate; the revision check makes an
/// unchanged channel a no-op.
Future<void> hydrateHostRuntimeState(
  Object reader,
  NetworkBackend backend,
) async {
  final updates = await backend.getHostRuntimeState();
  if (!identical(readProvider(reader, backendProvider), backend)) return;
  for (final update in updates) {
    applyHostRuntimeUpdate(reader, update, networkBackend: backend);
  }
}

/// Sends the values this client computes for
/// [RuntimeMirrorChannel.clientReports] channels to the host, so the host GUI
/// and other clients show a centering run or autofocus result started here.
final clientRuntimeReporterProvider = Provider<void>((ref) {
  final subscriptions = <ProviderSubscription<Object?>>[];
  final timers = <String, Timer>{};

  void teardown() {
    for (final sub in subscriptions) {
      sub.close();
    }
    subscriptions.clear();
    for (final timer in timers.values) {
      timer.cancel();
    }
    timers.clear();
  }

  ref.onDispose(teardown);

  final lastSent = <String, String>{};

  void send(NetworkBackend backend, RuntimeMirrorChannel<Object?> channel) {
    if (!identical(ref.read(backendProvider), backend)) return;
    final Map<String, dynamic>? value;
    try {
      value = channel.encodeCurrent(ref);
    } on Object catch (e) {
      developer.log(
        'Runtime report ${channel.key} not encoded: $e',
        name: _logSource,
        level: 900,
      );
      return;
    }
    // A provider can notify without changing what the host would be told.
    final encoded = jsonEncode(value);
    if (lastSent[channel.key] == encoded) return;
    lastSent[channel.key] = encoded;
    unawaited(
      backend
          .reportRuntimeState(
            channel: channel.key,
            value: value,
            origin: runtimeMirrorOrigin,
          )
          .catchError((Object e) {
            ref
                .read(loggingServiceProvider)
                .debug(
                  'Runtime report ${channel.key} not delivered: $e',
                  source: _logSource,
                );
          }),
    );
  }

  void bind(SkotiqBackend backend) {
    teardown();
    lastSent.clear();
    if (backend is! NetworkBackend) return;
    final mirrorState = ref.read(clientRuntimeMirrorStateProvider)..reset();
    for (final channel in ref.read(runtimeMirrorChannelsProvider)) {
      if (!channel.clientReports) continue;
      subscriptions.add(
        channel.listen(ref, (next) {
          // A value just applied from the host is the host's, not news. Only
          // an object can be told apart by identity: a null, string, number or
          // flag the host sent is identical to the same one produced here.
          final applied = mirrorState.appliedValue(channel.key);
          if (mirrorState.isApplying(channel.key) ||
              (applied != null &&
                  applied is! String &&
                  applied is! num &&
                  applied is! bool &&
                  identical(next, applied))) {
            return;
          }
          if (channel.minInterval == Duration.zero) {
            send(backend, channel);
            return;
          }
          timers[channel.key] ??= Timer(channel.minInterval, () {
            timers.remove(channel.key);
            send(backend, channel);
          });
        }),
      );
    }
  }

  ref.listen<SkotiqBackend>(
    backendProvider,
    (_, next) => bind(next),
    fireImmediately: true,
  );
});
