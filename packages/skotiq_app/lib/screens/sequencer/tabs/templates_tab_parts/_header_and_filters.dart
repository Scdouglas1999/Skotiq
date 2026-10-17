// Top-of-tab chrome and primary action chip: snippet summary card, header with search box, category filter chips, and the _ActionButton primitive.
part of '../templates_tab.dart';

/// "You have N reusable snippets, and they live on the Builder tab."
///
/// One SkotiqBanner with one action, in place of a tinted card with a
/// 40 px accent disc, an h5 title, a two-clause sentence and a bespoke button.
class _SnippetSummaryCard extends ConsumerWidget {
  final SkotiqColors colors;
  final int snippetCount;

  const _SnippetSummaryCard({
    required this.colors,
    required this.snippetCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SkotiqBanner(
      icon: LucideIcons.bookMarked,
      title: countLabel(snippetCount, 'reusable snippet'),
      message: 'Add them from the Snippets panel in the Builder.',
      action: SkotiqButton(
        label: 'Go to Builder',
        icon: LucideIcons.arrowRight,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        onPressed: () {
          // Switch to Builder tab and show snippets
          ref.read(sequencerTabProvider.notifier).state = 0;
          ref.read(snippetPaletteVisibleProvider.notifier).state = true;
        },
      ),
    );
  }
}

class _TemplatesHeader extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const _TemplatesHeader({required this.colors});

  @override
  ConsumerState<_TemplatesHeader> createState() => _TemplatesHeaderState();
}

class _TemplatesHeaderState extends ConsumerState<_TemplatesHeader> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    // Measured at 1000x800: the single-row desktop header packs the search
    // box, the wizard and Save-as-Template beside the title, leaving it ~130px
    // — below even the shrink floor's needs — so the tab stops naming itself.
    // The stacked header is the honest layout until the row genuinely fits:
    // title needs ~260px beside ~570px of toolbar plus the nav rail, so the
    // fork sits at 1100.
    final isNarrow = screenWidth < 1100;
    final current = ref.watch(currentSequenceProvider);
    final editingTemplate =
        current?.isTemplate == true && current?.databaseId != null;

    if (isMobile || isNarrow) {
      return _buildMobileHeader(editingTemplate: editingTemplate);
    }
    return _buildDesktopHeader(editingTemplate: editingTemplate);
  }

  /// The desktop search field's width.
  static const double _searchFieldWidth = 250;

  Widget _buildMobileHeader({required bool editingTemplate}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title row with save button
        Row(
          children: [
            // No title block: the page header names the screen and the
            // underline tab names the tab.
            const Spacer(),
            // Quick-start wizard
            SkotiqButton(
              label: 'Wizard',
              icon: LucideIcons.wand2,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (context) => const QuickStartWizardDialog(),
                );
              },
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            // Save current as template button
            SkotiqButton(
              label: editingTemplate ? 'Update' : 'Save',
              icon: LucideIcons.save,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => _showSaveTemplateDialog(context),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        // Search field - full width on mobile
        SkotiqTextField(
          controller: _searchController,
          hint: 'Search templates',
          prefixIcon: LucideIcons.search,
          onChanged: (value) {
            ref.read(templateSearchProvider.notifier).state = value;
          },
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        _CategoryFilter(colors: widget.colors),
      ],
    );
  }

  Widget _buildDesktopHeader({required bool editingTemplate}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // No title block: the page header names the screen and the
            // underline tab names the tab. The filter row keeps the space.
            const Spacer(),

            const SizedBox(width: 16),

            SizedBox(
              width: _searchFieldWidth,
              child: SkotiqTextField(
                controller: _searchController,
                hint: 'Search templates',
                prefixIcon: LucideIcons.search,
                onChanged: (value) {
                  ref.read(templateSearchProvider.notifier).state = value;
                },
              ),
            ),

            const SizedBox(width: SkotiqTokens.spaceSm),

            SkotiqButton(
              label: 'Wizard',
              icon: LucideIcons.wand2,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (context) => const QuickStartWizardDialog(),
                );
              },
            ),

            const SizedBox(width: SkotiqTokens.spaceSm),

            SkotiqButton(
              label: editingTemplate ? 'Update template' : 'Save as template',
              icon: LucideIcons.save,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => _showSaveTemplateDialog(context),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        _CategoryFilter(colors: widget.colors),
      ],
    );
  }

  void _showSaveTemplateDialog(BuildContext context) {
    final currentSequence = ref.read(currentSequenceProvider);
    if (currentSequence == null) {
      context.showErrorSnackBar('No sequence to save as template');
      return;
    }

    showDialog(
      context: context,
      builder: (context) => _SaveTemplateDialog(
        colors: widget.colors,
        sequence: currentSequence,
      ),
    );
  }
}

/// All / Beginner / Intermediate / Advanced / Specialized.
///
/// One choice out of five mutually exclusive ones is a [SegmentedControl],
/// not five Material `FilterChip`s with tick marks (06 §Sequencer): a chip
/// row invites multi-select and these categories cannot combine.
class _CategoryFilter extends ConsumerWidget {
  final SkotiqColors colors;

  const _CategoryFilter({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedCategory = ref.watch(templateCategoryProvider);
    final selectedIndex = _templateCategoryOptions.indexWhere(
      (option) => option.key == selectedCategory,
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedControl(
        segments: <String>[
          for (final option in _templateCategoryOptions) option.value,
        ],
        selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
        onSelected: (index) => ref
            .read(templateCategoryProvider.notifier)
            .state = _templateCategoryOptions[index].key,
      ),
    );
  }
}
