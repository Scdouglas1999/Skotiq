part of '../stack_and_share_service.dart';

/// The most frequent entry of a reason → count tally.
String _dominantReason(Map<String, int> tally) {
  if (tally.isEmpty) return 'unknown';
  var best = '';
  var bestCount = -1;
  tally.forEach((reason, count) {
    if (count > bestCount) {
      best = reason;
      bestCount = count;
    }
  });
  return best;
}
