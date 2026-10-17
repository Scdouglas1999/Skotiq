part of '../centering_service.dart';

extension _CenteringSlewSettle on CenteringService {
  /// Poll the mount until `slewing == false`, the overall poll cap is hit, or
  /// abort is requested.
  ///
  /// Two distinct timeouts protect this loop:
  ///   1. [_maxPollTicks] (60s wall-clock) — upper bound for a
  ///      slow-but-working mount that just hasn't finished slewing yet.
  ///   2. [_maxConsecutiveQueryFailures] (3s of unbroken errors) — fail-fast
  ///      escalation when the mount stops answering at all (disconnected,
  ///      driver crashed, COM hung). A single transient failure resets on
  ///      the next successful poll and never trips this; only sustained
  ///      brokenness escalates by throwing
  ///      [CenteringMountUnresponsiveException].
  Future<void> _waitForSlewComplete(String mountId) async {
    await Future.delayed(_pollInterval);
    int pollCount = 0;
    int consecutiveQueryFailures = 0;
    Object? lastQueryError;
    while (pollCount < _maxPollTicks && !_abortRequested) {
      try {
        final status = await _backend.getMountStatus(mountId);
        // Success — clear the consecutive-failure counter. A single
        // transient error followed by a good poll must NOT escalate.
        consecutiveQueryFailures = 0;
        lastQueryError = null;
        if (!status.slewing) {
          return;
        }
      } on CenteringMountUnresponsiveException {
        // Never wrap our own escalation — preserve the original frame.
        rethrow;
      } on Object catch (e) {
        consecutiveQueryFailures++;
        lastQueryError = e;
        // ignore: avoid_print
        print(
          'CenteringService: post-slew status poll failed '
          '($consecutiveQueryFailures/${CenteringService._maxConsecutiveQueryFailures}): $e',
        );

        if (consecutiveQueryFailures >=
            CenteringService._maxConsecutiveQueryFailures) {
          // Escalate the sustained outage as a typed exception so the
          // caller reports a precise failure reason in [CenteringResult]
          // rather than riding out the 60s cap.
          throw CenteringMountUnresponsiveException(
            consecutiveFailures: consecutiveQueryFailures,
            elapsed: _pollInterval * consecutiveQueryFailures,
            cause: lastQueryError,
          );
        }
      }
      await Future.delayed(_pollInterval);
      pollCount++;
    }

    if (!_abortRequested) {
      throw CenteringSlewTimeoutException(
        elapsed: _pollInterval * _maxPollTicks,
      );
    }
  }
}
