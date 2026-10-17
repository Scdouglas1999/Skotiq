/// When a failed delivery is tried again, and when it stops being tried.
///
/// The schedule is a pure function of the journal row: `attempts` gives the
/// delay and `updated_at` gives the clock it runs from. Nothing is held in
/// memory, so the sweep that runs after a restart makes exactly the same
/// decisions the process that died would have made.
library;

import '../../models/darkroom/delivery.dart';

/// Bounded exponential backoff across the night.
class DeliveryRetryPolicy {
  /// How many attempts one file gets on one destination before the journal
  /// records it as failed. The first attempt counts, so `maxAttempts: 1` means
  /// no retry at all.
  final int maxAttempts;

  /// Delay after the first failed attempt.
  final Duration firstBackoff;

  /// Factor each successive delay is multiplied by.
  final double multiplier;

  /// Ceiling on the delay, so a long night does not end with one attempt
  /// every four hours.
  final Duration maxBackoff;

  const DeliveryRetryPolicy({
    this.maxAttempts = 8,
    this.firstBackoff = const Duration(minutes: 1),
    this.multiplier = 3,
    this.maxBackoff = const Duration(minutes: 30),
  });

  /// The default schedule: 1 m, 3 m, 9 m, 27 m, then 30 m, over 8 attempts —
  /// a little over three hours, which is the shape of the window between a
  /// dawn job finishing and the operator waking up.
  static const DeliveryRetryPolicy standard = DeliveryRetryPolicy();

  /// How long to wait after the attempt numbered [attempts] failed.
  Duration backoffAfter(int attempts) {
    if (attempts <= 0) return Duration.zero;
    var delay = firstBackoff;
    for (var i = 1; i < attempts; i++) {
      delay *= multiplier;
      if (delay >= maxBackoff) return maxBackoff;
    }
    return delay > maxBackoff ? maxBackoff : delay;
  }

  /// Whether [attempts] has spent the budget.
  bool isExhausted(int attempts) => attempts >= maxAttempts;

  /// The earliest moment [entry] may be tried again.
  DateTime nextEligibleAt(DeliveryJournalEntry entry) =>
      entry.updatedAt.add(backoffAfter(entry.attempts));

  /// Whether [entry] is due for another attempt at [now].
  bool isDue(DeliveryJournalEntry entry, DateTime now) =>
      !now.toUtc().isBefore(nextEligibleAt(entry));
}
