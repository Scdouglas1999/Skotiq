part of '../targets_tab.dart';

class _TargetsHeader extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const _TargetsHeader({required this.colors});

  @override
  ConsumerState<_TargetsHeader> createState() => _TargetsHeaderState();
}

class _TargetsHeaderState extends ConsumerState<_TargetsHeader> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typeFilter = ref.watch(targetTypeFilterProvider);

    return Row(
      children: [
        // Search
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: widget.colors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: widget.colors.border),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.search,
                  size: 16,
                  color: widget.colors.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (value) {
                      ref.read(sequenceTargetSearchProvider.notifier).state =
                          value;
                    },
                    style: TextStyle(
                      fontSize: 13,
                      color: widget.colors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search targets...',
                      hintStyle: TextStyle(
                        fontSize: 13,
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
                      _searchController.clear();
                      ref.read(sequenceTargetSearchProvider.notifier).state =
                          '';
                    },
                    child: Icon(
                      LucideIcons.x,
                      size: 16,
                      color: widget.colors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ),

        const SizedBox(width: 16),

        // Type filter
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: widget.colors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: widget.colors.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: typeFilter,
              hint: Text(
                'All Types',
                style: TextStyle(
                  fontSize: 13,
                  color: widget.colors.textSecondary,
                ),
              ),
              icon: Icon(
                LucideIcons.chevronDown,
                size: 16,
                color: widget.colors.textMuted,
              ),
              dropdownColor: widget.colors.surface,
              style: TextStyle(fontSize: 13, color: widget.colors.textPrimary),
              items: const [
                DropdownMenuItem(value: null, child: Text('All Types')),
                DropdownMenuItem(value: 'Galaxy', child: Text('Galaxies')),
                DropdownMenuItem(value: 'Nebula', child: Text('Nebulae')),
                DropdownMenuItem(value: 'Cluster', child: Text('Clusters')),
                DropdownMenuItem(value: 'Star', child: Text('Stars')),
                DropdownMenuItem(value: 'Planet', child: Text('Planets')),
              ],
              onChanged: (value) {
                ref.read(targetTypeFilterProvider.notifier).state = value;
              },
            ),
          ),
        ),

        const SizedBox(width: 16),

        // Add button
        _ActionButton(
          colors: widget.colors,
          icon: LucideIcons.plus,
          label: 'Add Target',
          isPrimary: true,
          onPressed: () => _showAddTargetDialog(context),
        ),

        const SizedBox(width: 8),

        // Import button
        _ActionButton(
          colors: widget.colors,
          icon: LucideIcons.download,
          label: 'Import',
          onPressed: () async {
            try {
              final file = await file_selector.openFile(
                acceptedTypeGroups: [
                  const file_selector.XTypeGroup(
                    label: 'CSV or JSON',
                    extensions: ['csv', 'json'],
                  ),
                ],
              );

              if (file == null) return;

              final content = await file.readAsString();
              final extension = file.name.split('.').last.toLowerCase();

              final importer = TargetLibraryImporter(
                ref.read(databaseProvider),
              );
              final int importedCount;
              if (extension == 'csv') {
                importedCount = await importer.importCsv(content);
              } else if (extension == 'json') {
                importedCount = await importer.importJson(content);
              } else {
                throw const TargetLibraryImportException(
                  'Choose a .csv or .json target file.',
                );
              }

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Imported $importedCount '
                      'target${importedCount == 1 ? '' : 's'}',
                    ),
                  ),
                );
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to import targets: $e')),
                );
              }
            }
          },
        ),
      ],
    );
  }

  void _showAddTargetDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const _AddTargetDialog(),
    );
  }
}
