// Settings search synonyms, ranking and row matching helpers.
part of '../settings_screen.dart';

/// Words a user types for a setting that the owning page never says.
///
/// The app's own vocabulary does not always match the owning page's: the
/// Dashboard says "Set a capture directory to track free space" and the status
/// bar says "No save path", while Files & Storage titles that row "Image
/// output".
///
/// Kept small and deliberate: a synonym that is too generous makes the search
/// match everything.
const Map<String, List<String>> kSettingsSearchSynonyms = {
  'files-storage': [
    'capture folder',
    'capture directory',
    'save path',
    'image folder',
    'disk space',
    'free space',
    'storage location',
  ],
};

/// Whether [section] answers a single search token, including the synonyms
/// above. Exposed so tests can exercise the same predicate the screen uses.
bool sectionMatchesToken(SettingsSectionDef section, String token) {
  if (section.matches(token)) return true;
  for (final synonym in kSettingsSearchSynonyms[section.key] ?? const []) {
    if (synonym.contains(token)) return true;
  }
  return false;
}

/// How well [section] answers [query]; lower sorts first.
///
/// Exact section titles outrank a row title that merely contains the query,
/// which is what kept sending an autofocus search to a page ranked above the
/// page the setting is actually on.
int settingsMatchRank(SettingsSectionDef section, String query) {
  final label = section.label.toLowerCase();
  if (label == query) return 0;
  if (label.contains(query)) return 1;
  var best = 4;
  for (final term in kSettingsSearchTerms[section.key] ?? const <String>[]) {
    final lower = term.toLowerCase();
    if (lower == query) return 2;
    if (lower.startsWith(query) && best > 3) best = 3;
  }
  return best;
}

/// A section that answered the query, plus the rows inside it that did.
///
/// The row titles were being computed and thrown away: the sidebar showed
/// "Connection" for a query of "Alpaca" and left the operator to find the
/// Alpaca row on a long page by eye.
class SettingsSearchResult {
  const SettingsSearchResult(this.section, this.rows);

  final SettingsSectionDef section;

  /// Matching row titles, best (shortest, i.e. most title-like) first. Empty
  /// when the section's own name or a synonym is what matched.
  final List<String> rows;
}

/// Does [term] look like the NAME of a setting, rather than prose about one?
///
/// The generated index is not a list of row titles. Its `title:` rule has no
/// left word boundary, so every `subtitle:` in the settings tree is indexed as
/// well — that is how "Where rejected frames go. Leave blank for the default
/// `<save_path>/Reject/…`" (164 characters) ends up in it. That was harmless
/// while the index only decided which SECTIONS matched, but a result list that
/// offers those strings as tappable rows offers dead ends: nothing on the page
/// is titled that, so opening it reveals and marks nothing — exactly the
/// complaint the row results were added to fix.
///
/// Measured over the 508 `title:` and 222 `subtitle:` literals under
/// `screens/settings/`: 99% of titles are <= 39 characters and <= 6 words,
/// while the median subtitle is 43 characters and 7 words.
bool isRowShapedSettingsTerm(String term) {
  final trimmed = term.trim();
  if (trimmed.isEmpty || trimmed.length > 48) return false;
  if (trimmed.split(RegExp(r'\s+')).length > 6) return false;
  // A sentence is prose; a row name never ends in a full stop or a comma and
  // never runs two sentences together.
  if (RegExp(r'[.,;]$').hasMatch(trimmed)) return false;
  if (trimmed.contains('. ')) return false;
  return true;
}

/// Does [token] begin a word in [lowerTerm]?
///
/// A bare `contains` made "gain" match "try ag[ain]." and "port" match
/// "sup[port]" and "re[port]ing_group_id" — results that have nothing to do
/// with what was typed. Sections keep the looser substring test
/// ([sectionMatchesToken]); only the row list, which claims to name the
/// setting that matched, is held to a word boundary.
bool _startsWord(String lowerTerm, String token) {
  if (token.isEmpty) return false;
  var from = 0;
  while (true) {
    final at = lowerTerm.indexOf(token, from);
    if (at < 0) return false;
    if (at == 0 || !RegExp(r'[a-z0-9]').hasMatch(lowerTerm[at - 1])) {
      return true;
    }
    from = at + 1;
  }
}

/// Row titles inside [section] that answer every token of the query.
///
/// Shortest first: the index holds row titles, page headings and control
/// labels, and the short entries are the ones that are actually a row's name.
List<String> matchingSettingsRows(
  SettingsSectionDef section,
  List<String> tokens, {
  int limit = 3,
}) {
  final matches = <String>[];
  final sectionLabel = section.label.toLowerCase();
  for (final term in kSettingsSearchTerms[section.key] ?? const <String>[]) {
    if (!isRowShapedSettingsTerm(term)) continue;
    final lower = term.toLowerCase();
    // A page whose own heading repeats the section name ("Notifications"
    // inside Notifications) would be offered as a child of the entry directly
    // above it, which says nothing new and cannot be tapped anywhere better.
    if (lower == sectionLabel) continue;
    if (tokens.every((token) => _startsWord(lower, token))) matches.add(term);
  }
  mergeSort<String>(matches, compare: (a, b) => a.length.compareTo(b.length));
  return matches.take(limit).toList();
}
