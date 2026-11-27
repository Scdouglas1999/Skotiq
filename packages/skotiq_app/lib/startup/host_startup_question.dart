import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart' show BackendConnectionState;
import 'package:skotiq_core/providers.dart';

import '../utils/startup_surface_queue.dart';

/// A start-up question about the imaging host's state, asked when the host is
/// here.
///
/// A client that has not reached its host has nothing to ask about: asking
/// the disconnected backend fails, and this device's database is not the
/// host's. So the question waits for the link, its [surfaces]' turns passed
/// meanwhile so the prompts after them are not held by a link that may never
/// come, and the link takes the turns again and asks.
///
/// The owner keeps whether it has asked, and decides whether a client asks
/// again after it leaves its host or comes back on the same link after a
/// drop ([listen]).
class HostStartupQuestion {
  HostStartupQuestion({
    required WidgetRef ref,
    required StartupSurfaceQueue queue,
    required List<StartupSurface> surfaces,
    required bool Function() mounted,
  })  : _ref = ref,
        _queue = queue,
        _surfaces = surfaces,
        _mounted = mounted;

  final WidgetRef _ref;
  final StartupSurfaceQueue _queue;
  final List<StartupSurface> _surfaces;
  final bool Function() _mounted;

  /// The backend whose link dropped, kept across the owner's rebuilds; a
  /// different backend is a new link, which [listen] asks about on its own.
  SkotiqBackend? _droppedOn;

  bool get _isClient => _ref.read(isRemoteClientProvider);

  /// A client launch whose host is not linked yet.
  bool get waitsForHost =>
      _isClient && !_ref.read(backendProvider).hostPlace.isLinked;

  /// Announces the turns. Call when the owner mounts, before any `await`.
  void expectTurns() {
    for (final surface in _surfaces) {
      _queue.expect(surface);
    }
  }

  /// Gives up the turns: nothing to show, or the owner is gone.
  void passTurns() {
    for (final surface in _surfaces) {
      _queue.pass(surface);
    }
  }

  /// True when the question can be asked now. While it waits for the host,
  /// the turns are passed and this is false.
  bool readyToAsk() {
    if (!waitsForHost) return true;
    passTurns();
    return false;
  }

  /// Asks once the link comes up. Call from the owner's `build`.
  ///
  /// [asked] says whether the owner has asked already; [ask] asks. When
  /// [forgetOnLeavingHost] is given, a client that leaves a linked host calls
  /// it, so the next link asks again. When [forgetOnReturn] is given, a
  /// client back on the same link after a drop calls it, and asks again when
  /// it returns true.
  void listen({
    required bool Function() asked,
    required void Function() ask,
    VoidCallback? forgetOnLeavingHost,
    bool Function()? forgetOnReturn,
  }) {
    void askAfterLink() {
      // The listener can run before the owner's read of the provider sees
      // the new backend, so the question is asked after the frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_mounted() || asked() || waitsForHost) return;
        expectTurns();
        ask();
      });
    }

    _ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (!_isClient) return;
      if (forgetOnLeavingHost != null &&
          previous != null &&
          !identical(previous, next) &&
          previous.hostPlace.isLinked) {
        forgetOnLeavingHost();
      }
      if (!next.hostPlace.isLinked || asked()) return;
      askAfterLink();
    });
    if (forgetOnReturn != null) {
      _ref.listen<AsyncValue<BackendConnectionState?>>(hostLinkStateProvider, (
        _,
        next,
      ) {
        if (!_isClient) return;
        final backend = _ref.read(backendProvider);
        switch (next.valueOrNull) {
          case BackendConnectionState.reconnecting ||
                BackendConnectionState.disconnected ||
                BackendConnectionState.error:
            _droppedOn = backend;
          case BackendConnectionState.connected:
            final returned = identical(_droppedOn, backend);
            _droppedOn = null;
            if (!returned || !forgetOnReturn()) return;
            askAfterLink();
          case BackendConnectionState.connecting || null:
            break;
        }
      });
    }
  }
}
