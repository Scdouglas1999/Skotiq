/// A choice a location carries as one word of its query, such as the tab in
/// `/planner?tab=scheduler`.
mixin QueryWord on Enum {
  /// The word links are written with.
  String get word;

  /// Words that older builds, notifications and docs wrote for this value.
  /// They keep resolving so a link that once worked still lands here.
  List<String> get olderWords;
}

/// The value of [values] that [word] names, ignoring case; null for null or
/// an unknown word, so the caller decides the fallback.
T? readQueryWord<T extends QueryWord>(List<T> values, String? word) {
  if (word == null) return null;
  final wanted = word.toLowerCase();
  for (final value in values) {
    if (value.word == wanted || value.olderWords.contains(wanted)) {
      return value;
    }
  }
  return null;
}
