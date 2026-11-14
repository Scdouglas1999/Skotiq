import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import 'backend_provider.dart';
import '../models/backend/backend_connection_state.dart';

/// The link to the imaging host this app controls, as it changes; null when
/// this app is not a remote client.
final hostLinkStateProvider = StreamProvider<BackendConnectionState?>((ref) {
  final link = ref.watch(backendProvider).remoteHost?.link;
  if (link == null) return Stream.value(null);
  return () async* {
    yield link.connectionState;
    yield* link.connectionStateStream;
  }();
});

/// The imaging host's name while the link to it is down, after it had been
/// up or while reconnecting; null while it is up, still making its first
/// connection, or when this app is not a remote client.
///
/// While it is set, every host value this app shows is the last one it heard,
/// not a live reading.
final hostLinkLostProvider = Provider<String?>((ref) {
  final link = ref.watch(backendProvider).remoteHost?.link;
  if (link == null) return null;
  final state =
      ref.watch(hostLinkStateProvider).valueOrNull ?? link.connectionState;
  return switch (state) {
    BackendConnectionState.reconnecting ||
    BackendConnectionState.disconnected ||
    BackendConnectionState.error => link.serverHost,
    BackendConnectionState.connecting ||
    BackendConnectionState.connected => null,
  };
});

/// How long a connected host may leave a heartbeat ping unanswered before the
/// link reads as not answering. A LAN round trip is milliseconds; this is
/// shorter than the 15 s heartbeat interval so one lost answer shows.
const Duration hostAnswerStaleAfter = Duration(seconds: 10);

/// Whole seconds the host has gone without answering, or null while it is
/// answering within [hostAnswerStaleAfter].
int? unansweredSecondsFor(HostLink backend) {
  final age = backend.unansweredPingAge;
  if (age == null || age < hostAnswerStaleAfter) return null;
  return age.inSeconds;
}

/// Whole seconds a connected host has left a heartbeat unanswered, checked
/// every second; null while it answers, while the link is down (then
/// [hostLinkLostProvider] is set) or when this app is not a remote client.
///
/// The socket can stay open while the host or the link under it stalls: on
/// 2026-11-03 answers took up to 47 s for two minutes and the socket never
/// closed. While it is set, every host value this app shows is the last one
/// it heard, not a live reading.
final hostUnansweredSecondsProvider = StreamProvider<int?>((ref) {
  final link = ref.watch(backendProvider).remoteHost?.link;
  if (link == null) return Stream.value(null);
  int? read() => link.connectionState == BackendConnectionState.connected
      ? unansweredSecondsFor(link)
      : null;
  final controller = StreamController<int?>();
  var last = read();
  controller.add(last);
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    final next = read();
    if (next == last) return;
    last = next;
    controller.add(next);
  });
  ref.onDispose(() {
    timer.cancel();
    controller.close();
  });
  return controller.stream;
});
