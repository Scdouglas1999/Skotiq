import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import 'backend_provider.dart';

/// The link to the imaging host this app controls, as it changes; null when
/// this app is not a remote client.
final hostLinkStateProvider = StreamProvider<BackendConnectionState?>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is! NetworkBackend) return Stream.value(null);
  return () async* {
    yield backend.connectionState;
    yield* backend.connectionStateStream;
  }();
});

/// The imaging host's name while the link to it is down, after it had been
/// up or while reconnecting; null while it is up, still making its first
/// connection, or when this app is not a remote client.
///
/// While it is set, every host value this app shows is the last one it heard,
/// not a live reading.
final hostLinkLostProvider = Provider<String?>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is! NetworkBackend) return null;
  final state =
      ref.watch(hostLinkStateProvider).valueOrNull ?? backend.connectionState;
  return switch (state) {
    BackendConnectionState.reconnecting ||
    BackendConnectionState.disconnected ||
    BackendConnectionState.error => backend.serverHost,
    BackendConnectionState.connecting ||
    BackendConnectionState.connected ||
    null => null,
  };
});
