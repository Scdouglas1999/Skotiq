import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../sequencer_screen.dart';
import 'package:skotiq_app/utils/authority_bound_dialog.dart';
import 'package:skotiq_app/utils/snackbar_helper.dart';
import '../widgets/quick_start_wizard_dialog.dart';
import '../../../utils/count_label.dart';
import '../sequence_counts.dart';

// File split: the rest of this library lives in `templates_tab_parts/`.
// Built-in template data (large hand-built node-tree literals) is kept in
// `_builtin_templates.dart` because it is data, not widgets; the remaining
// part files group widgets by purpose. All parts share this file's library
// scope via the `part` mechanism.

part 'templates_tab_parts/_builtin_templates.dart';
part 'templates_tab_parts/_builtin_core_nodes.dart';
part 'templates_tab_parts/_builtin_advanced_nodes.dart';
part 'templates_tab_parts/_builtin_specialty_nodes.dart';
part 'templates_tab_parts/_header_and_filters.dart';
part 'templates_tab_parts/_template_card.dart';
part 'templates_tab_parts/_save_template_dialog.dart';
part 'templates_tab_parts/_starters_section.dart';

/// Provider for the complete template catalog.
// autoDispose: list is only consumed by TemplatesTab; refetching the DB on
// revisit is cheap and reflects any templates the user just saved or
// imported elsewhere.
final sequenceTemplatesProvider =
    FutureProvider.autoDispose<List<Sequence>>((ref) async {
  final repository = ref.watch(sequenceRepositoryProvider);
  final dbTemplates = await repository.loadAllTemplates();
  // Built-ins are part of the product catalog, not an empty-database
  // placeholder, so they stay listed alongside the user's own.
  return [...dbTemplates, ..._getBuiltInTemplates()];
});

/// Search provider for templates
// autoDispose: filter input is tab-scoped.
final templateSearchProvider = StateProvider.autoDispose<String>((ref) => '');

/// Selected template category
// autoDispose: category filter is tab-scoped; default (All / null) is
// appropriate on each visit.
final templateCategoryProvider =
    StateProvider.autoDispose<String?>((ref) => null);

const _templateCategoryOptions = <MapEntry<String?, String>>[
  MapEntry<String?, String>(null, 'All'),
  MapEntry<String?, String>('beginner', 'Beginner'),
  MapEntry<String?, String>('intermediate', 'Intermediate'),
  MapEntry<String?, String>('advanced', 'Advanced'),
  MapEntry<String?, String>('specialized', 'Specialized'),
];

String _inferTemplateCategory(Sequence template) {
  final name = template.name.toLowerCase();

  if (name.contains('first light') ||
      name.contains('one-shot') ||
      name.contains('osc') ||
      name.contains('quick') ||
      name.contains('beginner')) {
    return 'beginner';
  }

  if (name.contains('unattended') ||
      name.contains('all-night') ||
      name.contains('remote observatory')) {
    return 'advanced';
  }

  if (name.contains('planetary') ||
      name.contains('solar') ||
      name.contains('lunar') ||
      name.contains('comet') ||
      name.contains('asteroid')) {
    return 'specialized';
  }

  return 'intermediate';
}

class TemplatesTab extends ConsumerWidget {
  const TemplatesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final templatesAsync = ref.watch(sequenceTemplatesProvider);
    final searchQuery = ref.watch(templateSearchProvider);
    final category = ref.watch(templateCategoryProvider);
    final isMobile = Responsive.isMobile(context);
    final snippets = ref.watch(allSnippetsProvider);

    return Padding(
      padding: EdgeInsets.all(isMobile ? 12 : 24),
      child: Column(
        children: [
          // Header
          _TemplatesHeader(colors: colors),

          const SizedBox(height: 24),

          // Snippet summary card (shows count and quick access hint)
          if (!isMobile && snippets.isNotEmpty)
            _SnippetSummaryCard(colors: colors, snippetCount: snippets.length),

          if (!isMobile && snippets.isNotEmpty) const SizedBox(height: 16),

          // Content — a single scroll view holding the bundled "Starters"
          // followed by the user's saved / built-in templates. Both honour the
          // search box; the category chips filter the templates section only.
          Expanded(
            child: ListView(
              children: [
                // Starters: bundled, read-only sample sequences. Only the
                // search box filters these — category is a template concept.
                _StartersSection(
                  colors: colors,
                  searchQuery: searchQuery,
                  isMobile: isMobile,
                ),

                // Built-in and user templates
                _TemplatesSectionHeader(
                  colors: colors,
                  icon: LucideIcons.fileStack,
                  title: 'Templates',
                  subtitle:
                      'Built-in recipes and templates you saved for quick reuse.',
                ),
                const SizedBox(height: 12),
                templatesAsync.when(
                  data: (templates) {
                    var filtered = templates;

                    // Apply search filter
                    if (searchQuery.isNotEmpty) {
                      filtered = filtered
                          .where((t) =>
                              t.name
                                  .toLowerCase()
                                  .contains(searchQuery.toLowerCase()) ||
                              t.description
                                  .toLowerCase()
                                  .contains(searchQuery.toLowerCase()))
                          .toList();
                    }

                    // Apply category filter
                    if (category != null && category.isNotEmpty) {
                      filtered = filtered
                          .where((template) =>
                              _inferTemplateCategory(template) == category)
                          .toList();
                    }

                    if (filtered.isEmpty) {
                      final hasSearch = searchQuery.isNotEmpty;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: EmptyState(
                          icon: hasSearch
                              ? LucideIcons.searchX
                              : LucideIcons.fileStack,
                          title: hasSearch
                              ? 'No templates found'
                              : 'No templates yet',
                          body: hasSearch
                              ? 'Try a different search term'
                              : 'Save your sequences as templates for easy '
                                  'reuse, or start from a Starter above',
                        ),
                      );
                    }

                    // Adapt grid for different screen sizes
                    final gridSpacing = isMobile ? 12.0 : 20.0;
                    final maxExtent = isMobile ? 320.0 : 400.0;

                    return GridView.builder(
                      // The outer ListView already scrolls; this grid lays
                      // out at its natural height inside it.
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      // A max-extent delegate chooses two ~195 px columns on
                      // a 430 px phone, far below what the card's actions and
                      // footer can lay out in. Mobile is deliberately one
                      // card wide; desktop keeps the adaptive multi-column
                      // grid.
                      gridDelegate: isMobile
                          ? SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 1,
                              childAspectRatio: 1.2,
                              mainAxisSpacing: gridSpacing,
                            )
                          : SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: maxExtent,
                              childAspectRatio: 1.3,
                              crossAxisSpacing: gridSpacing,
                              mainAxisSpacing: gridSpacing,
                            ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        return _TemplateCard(
                          colors: colors,
                          template: filtered[index],
                        );
                      },
                    );
                  },
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                        child: SkotiqMark(
                            motion: SkotiqMarkMotion.loading, size: 36)),
                  ),
                  error: (error, stack) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.alertTriangle,
                              size: 48, color: colors.error),
                          const SizedBox(height: 16),
                          Text(
                            'Failed to load templates',
                            style: SkotiqTypography.sectionTitle
                                .copyWith(color: colors.textPrimary),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            error.toString(),
                            style: SkotiqTypography.caption
                                .copyWith(color: colors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared section heading used to delineate the merged Templates tab into
/// "Starters" (bundled samples) and "Your Templates" (user-saved).
class _TemplatesSectionHeader extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String title;
  final String subtitle;

  const _TemplatesSectionHeader({
    required this.colors,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: colors.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: SkotiqTypography.sectionTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
