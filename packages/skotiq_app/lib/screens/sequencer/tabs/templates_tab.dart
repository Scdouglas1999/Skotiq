import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
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
part 'templates_tab_parts/_toolbar.dart';
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

/// Sequencer > Templates: the bundled starters, then the built-in and saved
/// templates, as cards as tall as their text.
class TemplatesTab extends ConsumerWidget {
  const TemplatesTab({super.key});

  List<Sequence> _filter(
    List<Sequence> templates,
    String query,
    String? category,
  ) {
    final q = query.toLowerCase();
    return [
      for (final template in templates)
        if ((q.isEmpty ||
                template.name.toLowerCase().contains(q) ||
                template.description.toLowerCase().contains(q)) &&
            (category == null ||
                category.isEmpty ||
                _inferTemplateCategory(template) == category))
          template,
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templatesAsync = ref.watch(sequenceTemplatesProvider);
    final searchQuery = ref.watch(templateSearchProvider);
    final category = ref.watch(templateCategoryProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < BreakpointTokens.breakpointPhone;
        return ListView(
          padding: compact
              ? SkotiqTokens.screenPaddingCompact
              : SkotiqTokens.screenPadding,
          children: [
            _TemplatesToolbar(compact: compact),
            const SizedBox(height: SkotiqTokens.space2xl),

            // Starters: bundled, read-only sample sequences. Only the search
            // filters them; category is a template concept.
            _StartersSection(searchQuery: searchQuery),

            const _CatalogSectionHead(
              title: 'Templates',
              clause: 'Built-in recipes and the templates you saved',
            ),
            templatesAsync.when(
              data: (templates) {
                final filtered = _filter(templates, searchQuery, category);
                if (filtered.isEmpty) {
                  final narrowed = searchQuery.isNotEmpty || category != null;
                  return EmptyState(
                    icon:
                        narrowed ? LucideIcons.searchX : LucideIcons.fileStack,
                    title: narrowed ? 'No templates match' : 'No templates yet',
                    body: narrowed
                        ? 'Try a different search or category.'
                        : 'Save a sequence as a template to reuse it here.',
                  );
                }
                return _CardGrid(
                  children: [
                    for (final template in filtered)
                      _TemplateCard(template: template),
                  ],
                );
              },
              loading: () => const Padding(
                padding: SkotiqTokens.padding2xl,
                child: Center(
                  child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
                ),
              ),
              error: (error, _) => EmptyState.error(
                title: 'Could not load templates',
                body: userFacingError(error),
                onRetry: () => ref.invalidate(sequenceTemplatesProvider),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A section head: the title in `sectionTitle` and a muted clause on the same
/// baseline.
class _CatalogSectionHead extends StatelessWidget {
  const _CatalogSectionHead({required this.title, required this.clause});

  final String title;
  final String clause;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: title,
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            TextSpan(
              text: '  $clause',
              style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lays cards out in one to three columns. Each card is as tall as its text;
/// the cards of one line share the tallest one's height so their buttons
/// line up.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.children});

  final List<Widget> children;

  static const double _gap = SkotiqTokens.spaceLg;

  static int _columnsFor(double width) {
    if (width < 640) return 1;
    if (width < 1100) return 2;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _columnsFor(constraints.maxWidth);
        final lines = <Widget>[];
        for (var start = 0; start < children.length; start += columns) {
          final end = (start + columns).clamp(0, children.length);
          lines.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = start; i < start + columns; i++) ...[
                    if (i > start) const SizedBox(width: _gap),
                    Expanded(
                      child: i < end ? children[i] : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const SizedBox(height: _gap),
              lines[i],
            ],
          ],
        );
      },
    );
  }
}

/// One starter or template: a neutral icon tile, the name, one muted facts
/// line, the description in full, then the card's buttons.
class _CatalogCard extends StatelessWidget {
  const _CatalogCard({
    required this.icon,
    required this.title,
    required this.facts,
    required this.description,
    required this.primary,
    this.actions = const <Widget>[],
  });

  final IconData icon;
  final String title;
  final String facts;
  final String description;

  /// The card's one labeled button ("Use this starter", "Use template").
  final Widget primary;

  /// At most two icon buttons after it.
  final List<Widget> actions;

  static const double _tileSize = SkotiqTokens.iconButtonSize;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return DecoratedBox(
      decoration: SkotiqDecorations.panel(colors),
      child: Padding(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: _tileSize,
                  height: _tileSize,
                  decoration: SkotiqDecorations.well(colors),
                  child: Icon(
                    icon,
                    size: SkotiqTokens.iconGlyphRow,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: SkotiqTypography.bodyStrong
                            .copyWith(color: colors.textPrimary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        facts,
                        style: SkotiqTypography.bodySm
                            .copyWith(color: colors.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              description,
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            const Spacer(),
            Row(
              children: [
                primary,
                const Spacer(),
                for (final action in actions) ...[
                  const SizedBox(width: SkotiqTokens.spaceXs),
                  action,
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
