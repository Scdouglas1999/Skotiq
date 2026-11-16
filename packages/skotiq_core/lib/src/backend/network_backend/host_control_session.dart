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
      final status = await sequencerGetStatus();
      return !const {
        'idle',
        'completed',
        'failed',
        'cancelled',
        'stopped',
        'error',
      }.contains(status.state.toLowerCase());
    } catch (_) {
      return true;
    }
  }
}
