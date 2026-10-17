import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// skotiq_backend.dart re-exports every role interface
// (DeviceBackend / GuidingBackend / ImagingBackend / SequencerBackend /
// ProfileSettingsBackend / DiagnosticsBackend) via its `roles/roles.dart`
// export, so role-typed providers below resolve without explicit imports.
import '../backend/skotiq_backend.dart';
import '../backend/ffi_backend.dart';
import '../backend/disconnected_backend.dart';
import '../backend/network_backend.dart';
import '../models/sequence/sequence_models.dart';
import 'database_provider.dart';
import 'equipment/equipment_state_reset.dart';
import 'sequence/sequence_progress.dart';
import '../services/device_service_lifecycle.dart';
import '../services/remote_sequence_editor_sync_lifecycle.dart';
import 'thumbnail_sidecar_provider.dart';

/// Factory seam for remote backends. Production uses [NetworkBackend.new];
/// tests can provide controllable candidates without opening sockets.
typedef NetworkBackendFactory =
    NetworkBackend Function({
      required String serverHost,
      required int serverPort,
      required int webSocketPort,
      required String scheme,
      String? pinnedFingerprint,
      String? authToken,
      required bool autoConnectWebSocket,
    });

/// A backend transition lost authority to a newer connect, disconnect, or
/// local-backend request. The newer request owns visible status and errors.
class BackendTransitionSupersededException implements Exception {
  const BackendTransitionSupersededException();

  @override
  String toString() => 'Backend transition was superseded by a newer request.';
}

/// Notifier for the backend implementation
class BackendNotifier extends StateNotifier<SkotiqBackend> {
  final Ref _ref;
  final NetworkBackendFactory _networkBackendFactory;
  Future<void> _swapTail = Future<void>.value();
  int _transitionGeneration = 0;

  BackendNotifier(
    this._ref, {
    NetworkBackendFactory networkBackendFactory = NetworkBackend.new,
  }) : _networkBackendFactory = networkBackendFactory,
       super(DisconnectedBackend());

  /// The backend currently owned by this notifier.
  ///
  /// Async provider operations capture the notifier before awaiting remote
  /// work, then use this value to reject a result from a backend that was
  /// replaced in the meantime. Reading Riverpod's [Ref] from such a stale
  /// continuation is unsafe because its dependencies may already have changed.
  SkotiqBackend get currentBackend => state;

  bool isCurrentBackend(SkotiqBackend backend) => identical(state, backend);

  /// Connect to a remote server and wait for the WebSocket event stream.
  ///
  /// When `collaborationViewerId` and `collaborationDisplayName` are
  /// supplied, the backend will emit a `collaboration.join` frame after
  /// the WS upgrade completes so the server can populate its viewer slot
  /// list. The server overrides the viewerId with the authenticated
  /// principal's digest when auth is enabled; supplying it from
  /// the client is still useful for (a) unauthenticated deployments and
  /// (b) keeping the wire shape consistent.
  Future<void> connect(
    String host,
    int port, {
    String? authToken,
    String scheme = 'http',
    String? pinnedFingerprint,
    String? collaborationViewerId,
    String? collaborationDeviceName,
    String? collaborationDisplayName,
  }) async {
    final transitionGeneration = ++_transitionGeneration;
    // [scheme] is `'http'` for LAN and `'https'` for a TLS-fronted tailnet /
    // Internet endpoint; NetworkBackend derives `ws`/`wss` from it. The
    // backend itself classifies [host] as LAN vs tailnet (via TailnetDetector)
    // and tunes its request/heartbeat/connection timeouts accordingly — LAN
    // behaviour is unchanged, remote sessions get longer ceilings to ride out
    // DERP-relay latency. [pinnedFingerprint], when supplied (paired rig),
    // makes the `/api/info` handshake fail closed on identity mismatch.
    final backend = _networkBackendFactory(
      serverHost: host,
      serverPort: port,
      webSocketPort: port,
      scheme: scheme,
      pinnedFingerprint: pinnedFingerprint,
      authToken: authToken,
      autoConnectWebSocket: false,
    );
    if (collaborationViewerId != null && collaborationDisplayName != null) {
      backend.setCollaborationIdentity(
        viewerId: collaborationViewerId,
        deviceName: collaborationDeviceName ?? collaborationDisplayName,
        displayName: collaborationDisplayName,
      );
    }
    // Install the connecting backend up front so the UI can render a
    // truthful "connecting" state (networkBackendConnectionStateProvider
    // subscribes to its connectionStateStream). If the handshake does not
    // reach a live connection we roll this back to an authoritative
    // DisconnectedBackend below — a refused/failed connection must never be
    // left installed where `backend is NetworkBackend` reads as "connected".
    try {
      await _swapBackend(backend, authorityGeneration: transitionGeneration);
    } catch (_) {
      // The candidate was never installed, so the notifier will never own or
      // dispose it. Release its HTTP client/controllers here (notably when an
      // active sequence correctly blocks changing hosts).
      if (!identical(state, backend)) backend.dispose();
      rethrow;
    }

    _throwIfSuperseded(backend, transitionGeneration);

    Object? failure;
    StackTrace? failureStack;
    try {
      await backend.connect();
    } catch (e, stackTrace) {
      failure = e;
      failureStack = stackTrace;
    }

    _throwIfSuperseded(backend, transitionGeneration);

    // NetworkBackend.connect() records handshake failures in its
    // connectionState rather than throwing: a refused `/api/info` probe, a
    // version mismatch, and a pinned-identity mismatch all resolve without an
    // exception. So the authoritative success signal is the live connection
    // state — not the absence of a thrown error, and not `backend is
    // NetworkBackend`. Only a `connected` state means the session is live.
    final connectionState = backend.connectionState;
    final connected =
        failure == null && connectionState == BackendConnectionState.connected;

    if (connected) {
      developer.log(
        '[BackendNotifier] NetworkBackend connected to $scheme://$host:$port '
        '(auth=${authToken != null && authToken.isNotEmpty}, '
        'remote=${backend.isRemoteHost}, '
        'pinned=${pinnedFingerprint != null && pinnedFingerprint.isNotEmpty})',
        name: 'BackendNotifier',
        level: 800,
      );
      return;
    }

    developer.log(
      '[BackendNotifier] NetworkBackend connect to $scheme://$host:$port did '
      'not reach a live connection (state=${connectionState.name}); rolling '
      'back to disconnected',
      name: 'BackendNotifier',
      level: 1000,
      error: failure,
      stackTrace: failureStack,
    );

    // Roll back to an authoritative disconnected state. Disposing the failed
    // backend (inside the swap) cancels its pending reconnect timer, closes
    // its event/state controllers, and releases the owned HTTP client so
    // nothing keeps retrying in the background after we report failure.
    await _rollbackFailedConnect(backend, transitionGeneration);

    // Surface the failure so callers see a refused connection as a failure
    // (and can keep the action retryable) instead of a silent success. The
    // original cause is preserved when one was thrown; otherwise we synthesize
    // a recoverable connection error describing the terminal handshake state.
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack ?? StackTrace.current);
    }
    throw SkotiqError(
      category: BackendErrorCategory.connection,
      message:
          'Connection to $scheme://$host:$port did not complete '
          '(state=${connectionState.name}).',
      userMessage:
          'Could not connect to the server at $host:$port. Check the address '
          'and that the server is running, then try again.',
      isRecoverable: true,
    );
  }

  /// Swap the failed [backend] out for a fresh [DisconnectedBackend]. Best
  /// effort: if the device-service quiesce that [_swapBackend] performs throws,
  /// force an authoritative disconnected state anyway (disposing the failed
  /// backend directly) so a failed connect never leaves the stale backend
  /// installed — even when teardown itself misbehaves.
  Future<void> _rollbackFailedConnect(
    SkotiqBackend backend,
    int transitionGeneration,
  ) async {
    if (!_ownsTransition(backend, transitionGeneration)) return;
    final disconnected = DisconnectedBackend();
    try {
      await _swapBackend(
        disconnected,
        expectedCurrent: backend,
        authorityGeneration: transitionGeneration,
      );
    } on BackendTransitionSupersededException {
      disconnected.dispose();
      return;
    } on Object catch (e, stackTrace) {
      developer.log(
        '[BackendNotifier] Rollback swap failed; forcing disconnected state: '
        '$e',
        name: 'BackendNotifier',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      if (_ownsTransition(backend, transitionGeneration)) {
        backend.dispose();
        state = DisconnectedBackend();
      }
    }
  }

  /// Disconnect from server and quiesce in-flight device operations first.
  Future<void> disconnect() async {
    final transitionGeneration = ++_transitionGeneration;
    await _swapBackend(
      DisconnectedBackend(),
      authorityGeneration: transitionGeneration,
    );
  }

  /// Flush host- or remote-owned sequence edits before the application exits.
  /// Unlike a normal backend swap, shutdown must surface a failed flush so the
  /// window can remain open instead of silently discarding the last edit.
  Future<void> prepareForShutdown() =>
      RemoteSequenceEditorSyncLifecycle.prepareForBackendSwap(
        state,
        requireSuccess: true,
      );

  /// Use local FFI backend (for Desktop/Headless)
  Future<void> useLocalBackend() async {
    final transitionGeneration = ++_transitionGeneration;
    final database = _ref.read(databaseProvider);
    // Share the container's sidecar service so the capture path's
    // fire-and-forget writes and the backend's on-demand reads use one
    // in-flight map — a frame being written as the UI asks for it is decoded
    // once — and so sidecar failures reach the structured logger.
    final backend = FfiBackend(
      database: database,
      thumbnailSidecars: _ref.read(thumbnailSidecarServiceProvider),
    );
    try {
      await _swapBackend(backend, authorityGeneration: transitionGeneration);
    } catch (_) {
      backend.dispose();
      rethrow;
    }
  }

  /// Quiesce the outgoing [DeviceService], reset equipment notifiers, then
  /// dispose the old backend. Fail-closed: quiesce timeout propagates so
  /// callers know the swap did not complete cleanly.
  Future<void> _swapBackend(
    SkotiqBackend newBackend, {
    SkotiqBackend? expectedCurrent,
    int? authorityGeneration,
  }) {
    final operation = _swapTail.then<void>((_) async {
      void ensureAuthority() {
        if ((expectedCurrent != null && !identical(state, expectedCurrent)) ||
            (authorityGeneration != null &&
                authorityGeneration != _transitionGeneration)) {
          throw const BackendTransitionSupersededException();
        }
      }

      ensureAuthority();
      await _performBackendSwap(newBackend, ensureAuthority: ensureAuthority);
    });
    // A rejected transition must not poison the queue; the next explicit
    // operator request still needs to run.
    _swapTail = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }

  Future<void> _performBackendSwap(
    SkotiqBackend newBackend, {
    required void Function() ensureAuthority,
  }) async {
    final oldBackend = state;
    if (identical(oldBackend, newBackend)) {
      return;
    }

    final launchInFlight = _ref.read(sequenceLaunchInFlightProvider);
    if (launchInFlight) {
      throw StateError(
        'Cannot change imaging host while a sequence launch is in progress. '
        'Wait for the launch to finish, then stop the sequence before '
        'disconnecting or switching hosts.',
      );
    }

    final executionState = _ref.read(sequenceExecutionStateProvider);
    final outgoingHostIsControllable =
        oldBackend is! DisconnectedBackend &&
        (oldBackend is! NetworkBackend ||
            oldBackend.connectionState == BackendConnectionState.connected);
    if (outgoingHostIsControllable && executionState.isBusy) {
      throw StateError(
        'Cannot change imaging host while the sequencer is '
        '${executionState.name}. Stop the active sequence first so control '
        'cannot be lost or transferred to a different rig.',
      );
    }

    // Give the remote sequence editor a chance to persist its latest dirty
    // document while the outgoing NetworkBackend is still usable. Doing this
    // after `state = newBackend` is too late: the old transport is disposed as
    // part of the swap and a listener cannot complete its HTTP request.
    await RemoteSequenceEditorSyncLifecycle.prepareForBackendSwap(oldBackend);
    ensureAuthority();

    try {
      await DeviceServiceLifecycle.prepareForBackendSwap();
    } on Object catch (e, stackTrace) {
      developer.log(
        '[BackendNotifier] DeviceService quiesce failed during backend swap: $e',
        name: 'BackendNotifier',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    ensureAuthority();

    resetAllEquipmentStateNotifiers(_ref);

    // Completed/failed progress belongs to the outgoing imaging host. When an
    // unreachable remote is explicitly abandoned we also clear its last known
    // live state; the remote rig may continue independently, but this client
    // must never offer run controls against the replacement backend.
    _ref.read(sequenceProgressProvider.notifier).reset();
    _ref.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.idle;

    oldBackend.dispose();
    state = newBackend;
  }

  bool _ownsTransition(SkotiqBackend backend, int transitionGeneration) =>
      transitionGeneration == _transitionGeneration &&
      identical(state, backend);

  void _throwIfSuperseded(SkotiqBackend backend, int transitionGeneration) {
    if (!_ownsTransition(backend, transitionGeneration)) {
      throw const BackendTransitionSupersededException();
    }
  }

  @override
  void dispose() {
    // Dispose current backend when provider is disposed
    state.dispose();
    super.dispose();
  }
}

/// Provider for the backend implementation
///
/// This is now a dynamic provider that can switch between:
/// - DisconnectedBackend (default for mobile)
/// - NetworkBackend (when mobile connects to server)
/// - FfiBackend (default for desktop/headless)
final backendProvider =
    StateNotifierProvider<BackendNotifier, SkotiqBackend>((ref) {
      return BackendNotifier(ref);
    });

/// Provider to check if we're in remote (network) mode
/// When true, file paths refer to the server filesystem, not local
final isRemoteModeProvider = Provider<bool>((ref) {
  final backend = ref.watch(backendProvider);
  return backend is NetworkBackend;
});

/// True when this process was LAUNCHED as a thin client of a remote imaging
/// host — the desktop's `--remote-host` flag — rather than as the machine that
/// owns the hardware.
///
/// This is the ROLE, which is fixed at launch. [isRemoteModeProvider] answers a
/// narrower question: whether a remote connection is open right now. The two
/// disagree for the whole of a client's life before its first successful
/// handshake, and again whenever the connection drops — and a surface that
/// decides WHOSE database it is editing has to read the role, because a
/// never-connected client owns none of the host's rows and a row it writes
/// locally is a row no dawn job will ever read.
///
/// Defaults to false: a process that never overrides it owns its own hardware.
/// The desktop entry point overrides it from the launch flags it already
/// parses.
final remoteClientLaunchProvider = Provider<bool>((ref) => false);

/// True when this process must treat the imaging host's data as another
/// machine's: it is connected to one now, or it was launched as one's client.
final isRemoteClientProvider = Provider<bool>((ref) {
  return ref.watch(remoteClientLaunchProvider) ||
      ref.watch(isRemoteModeProvider);
});

// Role-specific providers
// Each role provider exposes the active backend narrowed to the role
// interface it owns. New consumers SHOULD depend on the smallest role they
// need so the migration toward per-role consumers can proceed
// opportunistically without forcing every existing call site to change at
// once. All role providers `watch` the same [backendProvider] so swapping
// the underlying backend (FFI <-> Network <-> Disconnected) cascades to
// every role-typed dependent through the standard Riverpod graph.

/// Device-control slice of the active backend. See [DeviceBackend].
final deviceBackendProvider = Provider<DeviceBackend>((ref) {
  return ref.watch(backendProvider);
});

/// Guiding slice of the active backend. See [GuidingBackend].
final guidingBackendProvider = Provider<GuidingBackend>((ref) {
  return ref.watch(backendProvider);
});

/// Image-processing slice of the active backend. See [ImagingBackend].
final imagingBackendProvider = Provider<ImagingBackend>((ref) {
  return ref.watch(backendProvider);
});

/// Sequencer slice of the active backend. See [SequencerBackend].
final sequencerBackendProvider = Provider<SequencerBackend>((ref) {
  return ref.watch(backendProvider);
});

/// Profiles + persistent-settings slice of the active backend.
/// See [ProfileSettingsBackend].
final profileSettingsBackendProvider = Provider<ProfileSettingsBackend>((ref) {
  return ref.watch(backendProvider);
});

/// Cross-cutting diagnostics slice (event streams, dispose, plugin dispatch
/// flag, internet geolocation). See [DiagnosticsBackend].
final diagnosticsBackendProvider = Provider<DiagnosticsBackend>((ref) {
  return ref.watch(backendProvider);
});

/// Surface the WebSocket-level connection state of the current
/// [NetworkBackend] as a Riverpod stream. Distinct from OS-level WiFi
/// state (NetworkService) so the chip in the mobile UI can render the
/// two signals separately and stop conflating "WiFi up" with "WebSocket
/// alive".
///
/// Emits [BackendConnectionState.disconnected] when the active backend
/// is not a [NetworkBackend] (local FFI mode, or no session). Always
/// seeded with the current value so the indicator doesn't flash empty
/// on first build.
final networkBackendConnectionStateProvider =
    StreamProvider<BackendConnectionState>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is! NetworkBackend) {
        return Stream<BackendConnectionState>.value(
          BackendConnectionState.disconnected,
        );
      }
      // Prepend the current value so subscribers see the seed immediately
      // rather than waiting for the next transition.
      final controller = StreamController<BackendConnectionState>();
      controller.add(backend.connectionState);
      final sub = backend.connectionStateStream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      ref.onDispose(() {
        sub.cancel();
        controller.close();
      });
      return controller.stream;
    });

/// Whether the active backend can actually carry a command to an executor
/// right now.
///
/// Not the same question as [networkBackendConnectionStateProvider], which
/// reports `disconnected` for a perfectly healthy local host. A remote
/// controller whose host has gone away still holds a `NetworkBackend`
/// instance, so backend *type* alone cannot answer it either.
///
/// Run-control surfaces read this to avoid offering a Start button against an
/// unreachable host.
final backendCanCommandProvider = Provider<bool>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is DisconnectedBackend) return false;
  if (backend is NetworkBackend) {
    return ref.watch(networkBackendConnectionStateProvider).valueOrNull ==
        BackendConnectionState.connected;
  }
  return true;
});
