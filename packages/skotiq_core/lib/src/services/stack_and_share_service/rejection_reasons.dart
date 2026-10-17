part of '../stack_and_share_service.dart';

/// Compact, human-readable cause for a frame the stacker refused. The native
/// errors arrive wrapped (`SkotiqError.imageError(field0: …)`), so strip
/// the wrapper down to the sentence a user can act on.
String _rejectionReason(Object error) {
  var text = error.toString().trim();
  final field = RegExp(r'field0:\s*(.*?)\)\s*$', dotAll: true).firstMatch(text);
  if (field != null) text = field.group(1)!.trim();
  final colon = text.indexOf(': ');
  if (colon >= 0 && colon < 40 && text.startsWith(RegExp(r'[A-Za-z]'))) {
    // Drop a leading exception-type prefix ("StateError: …").
    final head = text.substring(0, colon);
    if (!head.contains(' ')) text = text.substring(colon + 2).trim();
  }
  return text.isEmpty ? 'unknown' : text;
}

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
