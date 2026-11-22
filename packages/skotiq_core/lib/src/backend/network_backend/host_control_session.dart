part of '../network_backend.dart';

/// Which client holds control of a linked imaging host, and whether a
/// run is in flight on it.
mixin HostControlSession on NetworkBackendTransport {
  Future<SequencerStatus> sequencerGetStatus();

  /// Remote-only: whether the host has a run in flight (running, paused,
  /// recovering, stopping). An unreadable state counts as in flight, so a
  /// caller deciding whether to offer recovery errs toward leaving it alone.
  Future<bool> hostRunInFlight() async {
    try {
      return (await sequencerGetStatus()).runState.mayBeInFlight;
    } catch (_) {
      return true;
    }
  }
}
