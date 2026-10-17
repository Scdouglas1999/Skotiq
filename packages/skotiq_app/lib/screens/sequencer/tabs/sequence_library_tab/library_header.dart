part of '../sequence_library_tab.dart';

class _LibraryHeader extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const _LibraryHeader({required this.colors});

  @override
  ConsumerState<_LibraryHeader> createState() => _LibraryHeaderState();
}

/// Width the desktop search field takes. Fixed rather than flexible so the
/// heading beside it is the control that absorbs the row's slack.
const double _searchFieldWidth = 250;

class _LibraryHeaderState extends ConsumerState<_LibraryHeader> {
  final _searchController = TextEditingController();

  // Debounce search input so the derived filter/sort pipeline doesn't
  // recompute on every keystroke (see findings: sort/filter churn).
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      ref.read(sequenceSearchProvider.notifier).state = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sortOrder = ref.watch(sequenceSortOrderProvider);

    // Keep the text field in sync when the search query is cleared from
    // elsewhere (e.g. the filtered empty-state "Clear search" action).
    ref.listen<String>(sequenceSearchProvider, (previous, next) {
      if (next.isEmpty && _searchController.text.isNotEmpty) {
        setState(_searchController.clear);
      }
    });

    if (Responsive.isMobile(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _buildSearch()),
              const SizedBox(width: 12),
              _ActionButton(
                colors: widget.colors,
                icon: LucideIcons.save,
                label: 'Save',
                isPrimary: true,
                onPressed: () => _showSaveSequenceDialog(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Spacer(),
              _buildSortControl(sortOrder),
            ],
          ),
        ],
      );
    }

    return Row(
      children: [
        // No title row: the page header names the screen and the underline tab
        // names the tab. The row is the tab's controls, right-aligned behind
        // the space they do not need.
        const Spacer(),

        const SizedBox(width: 16),

        // Sort dropdown
        _buildSortControl(sortOrder),

        const SizedBox(width: 16),

        // Search
        SizedBox(width: _searchFieldWidth, child: _buildSearch()),

        const SizedBox(width: 16),

        // Save current sequence button
        _ActionButton(
          colors: widget.colors,
          icon: LucideIcons.save,
          label: 'Save current',
          isPrimary: true,
          onPressed: () => _showSaveSequenceDialog(context),
        ),
      ],
    );
  }

  Widget _buildSortControl(SequenceSortOrder sortOrder) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: widget.colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: widget.colors.border),
      ),
      child: PopupMenuButton<SequenceSortOrder>(
        initialValue: sortOrder,
        onSelected: (value) {
          ref.read(sequenceSortOrderProvider.notifier).state = value;
        },
        itemBuilder: (context) => [
          _buildSortMenuItem(SequenceSortOrder.dateModified, 'Last Modified',
              LucideIcons.clock, sortOrder),
          _buildSortMenuItem(SequenceSortOrder.dateCreated, 'Date Created',
              LucideIcons.calendarPlus, sortOrder),
          _buildSortMenuItem(
              SequenceSortOrder.name, 'Name', LucideIcons.arrowUpAZ, sortOrder),
          _buildSortMenuItem(SequenceSortOrder.nodeCount, 'Node Count',
              LucideIcons.layers, sortOrder),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.arrowUpDown,
                size: 14, color: widget.colors.textMuted),
            const SizedBox(width: 8),
            Text(
              _getSortLabel(sortOrder),
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: widget.colors.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            Icon(LucideIcons.chevronDown,
                size: 14, color: widget.colors.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildSearch() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 250),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: widget.colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: widget.colors.border),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.search, size: 16, color: widget.colors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize13,
                color: widget.colors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'Search sequences...',
                hintStyle: TextStyle(
                  fontSize: SkotiqTypography.fontSize13,
                  color: widget.colors.textMuted,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          if (_searchController.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchDebounce?.cancel();
                setState(_searchController.clear);
                ref.read(sequenceSearchProvider.notifier).state = '';
              },
              child:
                  Icon(LucideIcons.x, size: 16, color: widget.colors.textMuted),
            ),
        ],
      ),
    );
  }

  PopupMenuItem<SequenceSortOrder> _buildSortMenuItem(
    SequenceSortOrder value,
    String label,
    IconData icon,
    SequenceSortOrder current,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon,
              size: 14,
              color: value == current
                  ? widget.colors.primary
                  : widget.colors.textMuted),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize13,
              color: value == current
                  ? widget.colors.primary
                  : widget.colors.textPrimary,
              fontWeight:
                  value == current ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          const Spacer(),
          if (value == current)
            Icon(LucideIcons.check, size: 14, color: widget.colors.primary),
        ],
      ),
    );
  }

  String _getSortLabel(SequenceSortOrder order) {
    switch (order) {
      case SequenceSortOrder.name:
        return 'Name';
      case SequenceSortOrder.dateModified:
        return 'Last Modified';
      case SequenceSortOrder.dateCreated:
        return 'Date Created';
      case SequenceSortOrder.nodeCount:
        return 'Node Count';
    }
  }

  void _showSaveSequenceDialog(BuildContext context) {
    final currentSequence = ref.read(currentSequenceProvider);
    if (currentSequence == null) {
      context.showErrorSnackBar('No sequence to save');
      return;
    }

    showDialog(
      context: context,
      builder: (context) => _SaveSequenceDialog(
        colors: widget.colors,
        sequence: currentSequence,
      ),
    );
  }
}
