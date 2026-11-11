import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../router/query_word.dart';

/// The top-level sequencer tabs, in display order.
///
/// Single source of truth for both the [TabController] length and the
/// [AdaptiveTabBar] strip — adding a tab here updates the controller, the
/// strip and the keyboard accelerator hints in one edit.
enum SequencerTab with QueryWord {
  builder('Builder', LucideIcons.workflow, 'builder', []),
  templates('Templates', LucideIcons.fileStack, 'templates', []),
  sequences('Saved', LucideIcons.folderOpen, 'sequences', ['library']),
  history('History', LucideIcons.history, 'history', ['runs']);

  const SequencerTab(this.label, this.icon, this.word, this.olderWords);

  final String label;

  /// Leading icon used in the strip + collapsed (icon-only) phone mode.
  final IconData icon;

  @override
  final String word;
  @override
  final List<String> olderWords;

  /// The tab a `?tab=` word names, or null.
  static SequencerTab? fromQuery(String? word) => readQueryWord(values, word);
}
