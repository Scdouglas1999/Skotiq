import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../utils/authority_bound_dialog.dart';
import '../../../utils/count_label.dart';

class ListsTab extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const ListsTab({super.key, required this.colors});

  @override
  ConsumerState<ListsTab> createState() => _ListsTabState();
}

class _ListsTabState extends ConsumerState<ListsTab> {
  @override
  Widget build(BuildContext context) {
    final listsAsync = ref.watch(observingListsProvider);
    final activeListId = ref.watch(activeObservingListIdProvider);

    return listsAsync.when(
      data: (lists) {
        if (lists.isEmpty) {
          return _buildEmptyState();
        }

        // If an active list is selected, show its items
        if (activeListId != null) {
          final activeList =
              lists.where((l) => l.id == activeListId).firstOrNull;
          if (activeList != null) {
            return _buildListItems(activeList);
          }
        }

        // Show all lists
        return _buildListSelector(lists, activeListId);
      },
      loading: () => const Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
      ),
      error: (e, _) => Center(
        child: Text('Error: $e', style: TextStyle(color: widget.colors.error)),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(SkotiqIcons.list, size: 48, color: widget.colors.textMuted),
            const SizedBox(height: 16),
            Text(
              'No observing lists',
              style: SkotiqTypography.h5
                  .copyWith(color: widget.colors.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              'Create a list to organize your targets for tonight\'s session.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: widget.colors.textMuted),
            ),
            const SizedBox(height: 16),
            _CreateListButton(colors: widget.colors),
          ],
        ),
      ),
    );
  }

  Widget _buildListSelector(List<ObservingList> lists, int? activeListId) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Observing Lists',
                style: SkotiqTypography.labelStrong
                    .copyWith(color: widget.colors.textPrimary),
              ),
              _CreateListButton(colors: widget.colors, compact: true),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: lists.length,
            itemBuilder: (context, index) {
              final list = lists[index];
              return _ObservingListCard(
                list: list,
                colors: widget.colors,
                onTap: () {
                  ref.read(activeObservingListIdProvider.notifier).state =
                      list.id;
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildListItems(ObservingList activeList) {
    final itemsAsync = ref.watch(observingListItemsProvider(activeList.id));

    return Column(
      children: [
        // Back button + list name header
        Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: widget.colors.border),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                icon: Icon(SkotiqIcons.chevronLeft,
                    size: 18, color: widget.colors.textPrimary),
                onPressed: () {
                  ref.read(activeObservingListIdProvider.notifier).state = null;
                },
                tooltip: 'Back to lists',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      activeList.name,
                      style: SkotiqTypography.labelStrong
                          .copyWith(color: widget.colors.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (activeList.description != null &&
                        activeList.description!.isNotEmpty)
                      Text(
                        activeList.description!,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize10,
                          color: widget.colors.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              _ExportToSequenceButton(
                listId: activeList.id,
                listName: activeList.name,
                colors: widget.colors,
              ),
            ],
          ),
        ),

        // List items
        Expanded(
          child: itemsAsync.when(
            data: (items) {
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(SkotiqIcons.add,
                            size: 32, color: widget.colors.textMuted),
                        const SizedBox(height: 12),
                        Text(
                          'List is empty',
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize13,
                            color: widget.colors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Click objects on the sky and use\n"Add to list" to populate it.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: widget.colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return _ObservingListItemCard(
                    item: item,
                    colors: widget.colors,
                    onTap: () => _lookAtItem(item),
                    onRemove: () => _removeItem(item),
                  );
                },
              );
            },
            loading: () => const Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
            ),
            error: (e, _) => Center(
              child: Text('Error: $e',
                  style: TextStyle(color: widget.colors.error)),
            ),
          ),
        ),
      ],
    );
  }

  void _lookAtItem(ObservingListItem item) {
    final coords = CelestialCoordinate(ra: item.ra, dec: item.dec);
    ref.read(skyViewStateProvider.notifier).lookAt(coords);
  }

  void _removeItem(ObservingListItem item) {
    ref.read(observingListNotifierProvider.notifier).removeItem(item.id);
  }
}

class _CreateListButton extends ConsumerWidget {
  final SkotiqColors colors;
  final bool compact;

  const _CreateListButton({required this.colors, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (compact) {
      return IconButton(
        icon: Icon(SkotiqIcons.add, size: 16, color: colors.primary),
        onPressed: () => _showCreateDialog(context),
        tooltip: 'Create new list',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      );
    }

    return GestureDetector(
      onTap: () => _showCreateDialog(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(SkotiqIcons.add, size: 14, color: colors.primary),
            const SizedBox(width: 6),
            Text(
              'Create List',
              style: SkotiqTypography.h6.copyWith(color: colors.primary),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const _CreateObservingListDialog(),
    );
  }
}

class _CreateObservingListDialog extends ConsumerStatefulWidget {
  const _CreateObservingListDialog();

  @override
  ConsumerState<_CreateObservingListDialog> createState() =>
      _CreateObservingListDialogState();
}

class _CreateObservingListDialogState
    extends ConsumerState<_CreateObservingListDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final SkotiqBackend _authority;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  bool _saving = false;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _descriptionController = TextEditingController();
    _authority = ref.read(backendProvider);
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next) || !mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('The connected host changed. List creation cancelled.'),
          ),
        );
        closeAuthorityBoundDialog(context);
      },
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter a list name');
      return;
    }
    if (!identical(ref.read(backendProvider), _authority)) return;

    setState(() {
      _saving = true;
      _nameError = null;
    });
    final description = _descriptionController.text.trim();
    final id =
        await ref.read(observingListNotifierProvider.notifier).createList(
              name: name,
              description: description.isEmpty ? null : description,
            );

    if (!mounted || !identical(ref.read(backendProvider), _authority)) return;
    if (id == null) {
      setState(() => _saving = false);
      final message = ref.read(observingListNotifierProvider).errorMessage ??
          'Could not create the observing list';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }

    ref.read(activeObservingListIdProvider.notifier).state = id;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Create Observing List'),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 400,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'List Name',
                  hintText: 'e.g., Winter Galaxies',
                  errorText: _nameError,
                ),
                autofocus: true,
                textInputAction: TextInputAction.next,
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'e.g., Best galaxies visible in winter',
                ),
                maxLines: 2,
                onSubmitted: (_) {
                  if (!_saving) _submit();
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: Text(_saving ? 'Creating…' : 'Create'),
          ),
        ],
      ),
    );
  }
}

class _ObservingListCard extends ConsumerWidget {
  final ObservingList list;
  final SkotiqColors colors;
  final VoidCallback onTap;

  const _ObservingListCard({
    required this.list,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(observingListItemsProvider(list.id));
    final itemCount = itemsAsync.valueOrNull?.length ?? 0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Icon(SkotiqIcons.list, size: 16, color: colors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    list.name,
                    style: SkotiqTypography.labelStrong
                        .copyWith(color: colors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$itemCount object${itemCount == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(SkotiqIcons.chevronRight, size: 14, color: colors.textMuted),
          ],
        ),
      ),
    );
  }
}

class _ObservingListItemCard extends StatefulWidget {
  final ObservingListItem item;
  final SkotiqColors colors;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _ObservingListItemCard({
    required this.item,
    required this.colors,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_ObservingListItemCard> createState() => _ObservingListItemCardState();
}

class _ObservingListItemCardState extends State<_ObservingListItemCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final showRemove = Responsive.isMobile(context) || _isHovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _isHovered
                ? widget.colors.surfaceAlt
                : widget.colors.background,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: _isHovered
                  ? widget.colors.primary.withValues(alpha: 0.5)
                  : widget.colors.border,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.item.objectName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SkotiqTypography.h6
                                .copyWith(color: widget.colors.textPrimary),
                          ),
                        ),
                        if (widget.item.catalogId != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color:
                                  widget.colors.primary.withValues(alpha: 0.15),
                              borderRadius:
                                  BorderRadius.circular(SkotiqTokens.radiusXs),
                            ),
                            child: Text(
                              widget.item.catalogId!,
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize9,
                                fontWeight: FontWeight.w600,
                                color: widget.colors.primary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (widget.item.objectType != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.item.objectType!,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize10,
                          color: widget.colors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.item.magnitude != null)
                Text(
                  'mag ${widget.item.magnitude!.toStringAsFixed(1)}',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    color: widget.colors.textMuted,
                  ),
                ),
              if (showRemove) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Remove from list',
                  child: IconButton(
                    onPressed: widget.onRemove,
                    icon: Icon(
                      SkotiqIcons.close,
                      size: 14,
                      color: widget.colors.error,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor:
                          widget.colors.error.withValues(alpha: 0.15),
                    ),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ExportToSequenceButton extends ConsumerStatefulWidget {
  final int listId;
  final String listName;
  final SkotiqColors colors;

  const _ExportToSequenceButton({
    required this.listId,
    required this.listName,
    required this.colors,
  });

  @override
  ConsumerState<_ExportToSequenceButton> createState() =>
      _ExportToSequenceButtonState();
}

class _ExportToSequenceButtonState
    extends ConsumerState<_ExportToSequenceButton> {
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _exporting ? 'Creating sequence…' : 'Export to Sequence',
      child: GestureDetector(
        onTap: _exporting ? null : _exportToSequence,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: widget.colors.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          ),
          child: _exporting
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: SkotiqSpinner(size: 14, color: widget.colors.primary),
                )
              : Icon(
                  LucideIcons.listPlus,
                  size: 14,
                  color: widget.colors.primary,
                ),
        ),
      ),
    );
  }

  Future<void> _exportToSequence() async {
    setState(() => _exporting = true);
    final backend = ref.read(backendProvider);
    final sequencesDao =
        backend is NetworkBackend ? null : ref.read(sequencesDaoProvider);
    int? sequenceId;
    try {
      // Read items through the remote-aware provider so a slave exports the
      // master's list (the local DAO is empty on a NetworkBackend).
      final items =
          await ref.read(observingListItemsProvider(widget.listId).future);

      if (items.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('List is empty, nothing to export.')),
          );
        }
        return;
      }

      if (backend is NetworkBackend) {
        sequenceId = await backend.createSequence({
          'name': widget.listName,
          'isTemplate': false,
        });
      } else {
        sequenceId = await sequencesDao!.createSequence(
          SequencesCompanion.insert(
            name: widget.listName,
            isTemplate: const Value(false),
          ),
        );
      }

      final nodeStamp = DateTime.now().microsecondsSinceEpoch;
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final nodeId = 'target_${nodeStamp}_$i';
        final properties = jsonEncode({
          'ra': item.ra,
          'dec': item.dec,
          if (item.catalogId != null) 'catalogId': item.catalogId,
        });
        if (backend is NetworkBackend) {
          await backend.createSequenceNode(sequenceId, {
            'nodeId': nodeId,
            'nodeType': 'target',
            'specificType': 'target',
            'name': item.objectName,
            'properties': properties,
            'orderIndex': i,
          });
        } else {
          await sequencesDao!.createNode(
            SequenceNodesCompanion.insert(
              nodeId: nodeId,
              sequenceId: sequenceId,
              nodeType: 'target',
              specificType: 'target',
              name: item.objectName,
              properties: Value(properties),
              orderIndex: Value(i),
            ),
          );
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Created sequence "${widget.listName}" with '
              '${countLabel(items.length, 'target')}',
            ),
          ),
        );
      }
    } catch (error) {
      Object? rollbackError;
      if (sequenceId != null) {
        try {
          if (backend is NetworkBackend) {
            await backend.deleteSequence(sequenceId);
          } else {
            await sequencesDao!.deleteSequence(sequenceId);
          }
        } catch (cleanupError) {
          rollbackError = cleanupError;
        }
      }
      if (mounted) {
        final cleanupDetail = rollbackError == null
            ? ''
            : ' The partial sequence could not be removed: $rollbackError';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not create sequence: $error.$cleanupDetail'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
}
