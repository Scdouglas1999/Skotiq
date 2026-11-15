part of '../templates_tab.dart';

/// Search and the category control at the left; the snippets shortcut and the
/// quick-start wizard at the right. On a phone the search and the wizard share
/// a line and the categories scroll beneath.
class _TemplatesToolbar extends ConsumerStatefulWidget {
  const _TemplatesToolbar({required this.compact});

  final bool compact;

  @override
  ConsumerState<_TemplatesToolbar> createState() => _TemplatesToolbarState();
}

class _TemplatesToolbarState extends ConsumerState<_TemplatesToolbar> {
  static const double _searchWidth = 280;

  late final TextEditingController _search =
      TextEditingController(text: ref.read(templateSearchProvider));

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openWizard() {
    showDialog<void>(
      context: context,
      builder: (context) => const QuickStartWizardDialog(),
    );
  }

  /// The Builder's Snippets panel, where saved snippets are added from.
  void _openSnippets() {
    ref.read(sequencerTabProvider.notifier).state = SequencerTab.builder.index;
    ref.read(snippetPaletteVisibleProvider.notifier).state = true;
  }

  @override
  Widget build(BuildContext context) {
    final snippetCount = ref.watch(allSnippetsProvider).length;
    final searchField = SkotiqSearchField(
      controller: _search,
      hint: 'Search starters and templates',
      onChanged: (value) =>
          ref.read(templateSearchProvider.notifier).state = value,
    );
    const category = _CategoryFilter();

    if (widget.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: searchField),
              const SizedBox(width: SkotiqTokens.spaceSm),
              SkotiqIconButton(
                icon: LucideIcons.wand2,
                tooltip: 'Quick start',
                onPressed: _openWizard,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: category,
          ),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: _searchWidth, child: searchField),
        const SizedBox(width: SkotiqTokens.spaceLg),
        const Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: category,
          ),
        ),
        const Spacer(),
        if (snippetCount > 0) ...[
          SkotiqButton(
            label: countLabel(snippetCount, 'snippet'),
            icon: LucideIcons.bookMarked,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            semanticsHint: 'Opens the Snippets panel in the Builder.',
            onPressed: _openSnippets,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
        ],
        SkotiqButton(
          label: 'Quick start',
          icon: LucideIcons.wand2,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: _openWizard,
        ),
      ],
    );
  }
}

/// The page-header action on the Templates tab: save the plan open in the
/// Builder as a template, or write an opened template back.
class SaveAsTemplateButton extends ConsumerWidget {
  const SaveAsTemplateButton({super.key, this.iconOnly = false});

  /// A phone header has room for a glyph, not the words.
  final bool iconOnly;

  void _save(BuildContext context, WidgetRef ref) {
    final current = ref.read(currentSequenceProvider);
    if (current == null) {
      context.showWarningSnackBar('There is no sequence in the Builder');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => _SaveTemplateDialog(
        colors: SkotiqColors.of(context),
        sequence: current,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentSequenceProvider);
    final editingTemplate =
        current?.isTemplate == true && current?.databaseId != null;
    final label = editingTemplate ? 'Update template' : 'Save as template';
    if (iconOnly) {
      return SkotiqIconButton(
        icon: LucideIcons.save,
        tooltip: label,
        onPressed: () => _save(context, ref),
      );
    }
    return SkotiqButton(
      label: label,
      icon: LucideIcons.save,
      variant: ButtonVariant.secondary,
      onPressed: () => _save(context, ref),
    );
  }
}

/// All / Beginner / Intermediate / Advanced / Specialized: one choice of five
/// that cannot combine, so a [SegmentedControl].
class _CategoryFilter extends ConsumerWidget {
  const _CategoryFilter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedCategory = ref.watch(templateCategoryProvider);
    final selectedIndex = _templateCategoryOptions.indexWhere(
      (option) => option.key == selectedCategory,
    );

    return SegmentedControl(
      semanticLabel: 'Template category',
      segments: <String>[
        for (final option in _templateCategoryOptions) option.value,
      ],
      selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
      onSelected: (index) => ref.read(templateCategoryProvider.notifier).state =
          _templateCategoryOptions[index].key,
    );
  }
}
