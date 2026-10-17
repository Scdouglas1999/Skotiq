import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The palette's result groups, in the order they are rendered.
///
/// Order is fixed rather than ranked: an operator who has typed three letters
/// is scanning, and a list whose sections move between keystrokes cannot be
/// scanned. Within a group the order is the app's own (rail order, catalog
/// order), for the same reason.
enum CommandGroup {
  /// Every rail destination, every Settings section, and the screens that have
  /// a route but no rail slot — which is what makes the palette the way those
  /// screens are reached at all.
  screens,

  /// Individual settings, from the generated `settings_search_index.g.dart`.
  /// Only matched entries appear; the unfiltered palette does not list 900
  /// rows of settings above the actions.
  settings,

  /// Things the palette DOES rather than opens.
  actions;

  String get label => switch (this) {
        CommandGroup.screens => 'Screens',
        CommandGroup.settings => 'Settings',
        CommandGroup.actions => 'Actions',
      };
}

/// One row in the command palette.
class CommandEntry {
  /// Stable identity, used as the widget key and for selection.
  final String id;

  final CommandGroup group;
  final IconData icon;
  final String label;

  /// Muted context on the right of the row — the settings group a setting
  /// lives in, or what an action will act on.
  final String? hint;

  /// Extra terms this entry answers to that are not in its label.
  final List<String> keywords;

  /// Whether this entry is offered at all right now. A disabled action still
  /// appears, greyed, with [disabledReason] as its hint: an action that
  /// vanishes when it cannot run leaves the operator searching for something
  /// that is not there.
  final bool enabled;
  final String? disabledReason;

  /// What the row does. Runs after the palette has closed, so a handler that
  /// pushes a route or opens a dialog is not fighting the palette's own
  /// dismissal.
  final void Function(BuildContext context, WidgetRef ref) invoke;

  const CommandEntry({
    required this.id,
    required this.group,
    required this.icon,
    required this.label,
    required this.invoke,
    this.hint,
    this.keywords = const [],
    this.enabled = true,
    this.disabledReason,
  });

  /// True when [query] (already lower-cased and trimmed) matches.
  bool matches(String query) {
    if (query.isEmpty) return true;
    if (label.toLowerCase().contains(query)) return true;
    for (final keyword in keywords) {
      if (keyword.toLowerCase().contains(query)) return true;
    }
    return false;
  }

  /// How well [query] matches, for ordering WITHIN a group.
  ///
  /// A prefix beats a word-start beats anything else, so typing "pl" puts
  /// "Plan" above "Polar alignment" instead of leaving the order to the
  /// catalog. Lower sorts first.
  int rank(String query) {
    if (query.isEmpty) return 0;
    final lower = label.toLowerCase();
    if (lower.startsWith(query)) return 0;
    if (RegExp(r'\b' + RegExp.escape(query)).hasMatch(lower)) return 1;
    if (lower.contains(query)) return 2;
    return 3;
  }
}
