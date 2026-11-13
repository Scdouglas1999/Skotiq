import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/authority_bound_dialog.dart';

class ObservingListsSettings extends ConsumerWidget {
  const ObservingListsSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final listsAsync = ref.watch(observingListsProvider);

    return SingleChildScrollView(
      padding: EdgeInsets.all(Responsive.isMobile(context) ? 12 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Observing Lists',
                style: SkotiqTypography.sectionTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              FilledButton.icon(
                onPressed: () => _showCreateDialog(context),
                icon: const Icon(LucideIcons.plus, size: 16),
                label: const Text('New List'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Manage your curated target collections for observing sessions.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),

          listsAsync.when(
            data: (lists) {
              if (lists.isEmpty) {
                return _buildEmptyState(context, ref, colors);
              }
              return Column(
                children: lists.map((list) {
                  return _ObservingListManagementCard(
                    list: list,
                  );
                }).toList(),
              );
            },
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
              ),
            ),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Could not load observing lists.',
                  style: SkotiqTypography.body.copyWith(
                    color: colors.error,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(
      BuildContext context, WidgetRef ref, SkotiqColors colors) {
    return SkotiqPanel(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          children: [
            Icon(LucideIcons.list, size: 48, color: colors.textMuted),
            const SizedBox(height: 16),
            Text(
              'No observing lists yet',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              'Create observing lists to organize your targets.\n'
              'You can add objects from the planetarium view.',
              textAlign: TextAlign.center,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _showCreateDialog(context),
              icon: const Icon(LucideIcons.plus, size: 16),
              label: const Text('Create Your First List'),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const _ObservingListEditorDialog(),
    );
  }
}

class _ObservingListManagementCard extends ConsumerWidget {
  final ObservingList list;

  const _ObservingListManagementCard({
    required this.list,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final itemsAsync = ref.watch(observingListItemsProvider(list.id));
    final itemCount = itemsAsync.valueOrNull?.length ?? 0;
    final isSaving = ref.watch(
      observingListNotifierProvider.select((state) => state.isSaving),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SkotiqPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.list, size: 18, color: colors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        list.name,
                        style: SkotiqTypography.sectionTitle.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      if (list.description != null &&
                          list.description!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            list.description!,
                            style: SkotiqTypography.caption.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Text(
                  '$itemCount object${itemCount == 1 ? '' : 's'}',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ActionChip(
                  icon: LucideIcons.pencil,
                  label: 'Rename',
                  onTap: () => _showRenameDialog(context),
                ),
                _ActionChip(
                  icon: LucideIcons.copy,
                  label: isSaving ? 'Duplicating…' : 'Duplicate',
                  onTap: isSaving
                      ? null
                      : () async {
                          final host = ref.backendScope();
                          final id = await ref
                              .read(observingListNotifierProvider.notifier)
                              .duplicateList(list.id);
                          if (!context.mounted || host.isStale) return;
                          final state = ref.read(observingListNotifierProvider);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(id == null
                                  ? (state.errorMessage ??
                                      'Could not duplicate list')
                                  : 'Duplicated "${list.name}"'),
                            ),
                          );
                        },
                ),
                _ActionChip(
                  icon: LucideIcons.trash2,
                  label: 'Delete',
                  isDestructive: true,
                  onTap: () => _showDeleteConfirmation(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _ObservingListEditorDialog(list: list),
    );
  }

  void _showDeleteConfirmation(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _DeleteObservingListDialog(list: list),
    );
  }
}

class _ObservingListEditorDialog extends ConsumerStatefulWidget {
  final ObservingList? list;

  const _ObservingListEditorDialog({this.list});

  @override
  ConsumerState<_ObservingListEditorDialog> createState() =>
      _ObservingListEditorDialogState();
}

class _ObservingListEditorDialogState
    extends ConsumerState<_ObservingListEditorDialog>
    with HostBoundDialogState<_ObservingListEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  @override
  String get hostChangedMessage =>
      'The connected host changed. List editing canceled.';

  bool _saving = false;
  String? _nameError;

  bool get _isEditing => widget.list != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.list?.name ?? '');
    _descriptionController =
        TextEditingController(text: widget.list?.description ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter a list name');
      return;
    }
    if (host.isStale) return;

    setState(() {
      _saving = true;
      _nameError = null;
    });
    final description = _descriptionController.text.trim();
    final notifier = ref.read(observingListNotifierProvider.notifier);
    final success = _isEditing
        ? await notifier.updateList(
            widget.list!.id,
            name: name,
            description: description.isEmpty ? null : description,
          )
        : await notifier.createList(
              name: name,
              description: description.isEmpty ? null : description,
            ) !=
            null;

    if (!mounted || host.isStale) return;
    if (!success) {
      setState(() => _saving = false);
      final state = ref.read(observingListNotifierProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(state.errorMessage ?? 'Could not save the list'),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_isEditing ? 'List updated' : 'List created')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title:
            Text(_isEditing ? 'Edit Observing List' : 'Create Observing List'),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 420,
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
                ),
                maxLines: 2,
                onSubmitted: (_) {
                  if (!_saving) _save();
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
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : (_isEditing ? 'Save' : 'Create')),
          ),
        ],
      ),
    );
  }
}

class _DeleteObservingListDialog extends ConsumerStatefulWidget {
  final ObservingList list;

  const _DeleteObservingListDialog({required this.list});

  @override
  ConsumerState<_DeleteObservingListDialog> createState() =>
      _DeleteObservingListDialogState();
}

class _DeleteObservingListDialogState
    extends ConsumerState<_DeleteObservingListDialog>
    with HostBoundDialogState<_DeleteObservingListDialog> {
  @override
  String get hostChangedMessage =>
      'The connected host changed. List deletion canceled.';

  bool _deleting = false;

  Future<void> _delete() async {
    if (host.isStale) return;
    setState(() => _deleting = true);
    final success = await ref
        .read(observingListNotifierProvider.notifier)
        .deleteList(widget.list.id);
    if (!mounted || host.isStale) return;
    if (!success) {
      setState(() => _deleting = false);
      final state = ref.read(observingListNotifierProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(state.errorMessage ?? 'Could not delete the list'),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted "${widget.list.name}"')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_deleting,
      child: AlertDialog(
        title: const Text('Delete List?'),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 420,
          ),
          child: Text(
            'This will permanently delete "${widget.list.name}" and all its '
            'items. This action cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: _deleting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          SkotiqButton(
            onPressed: _deleting ? null : _delete,
            label: 'Delete',
            variant: ButtonVariant.destructive,
            isLoading: _deleting,
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isDestructive;
  final VoidCallback? onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    this.isDestructive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final color = isDestructive ? colors.error : colors.textSecondary;

    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: isDestructive
              ? SkotiqDecorations.emphasisSurface(
                  colors.error,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                )
              : SkotiqDecorations.chip(colors, tone: colors.primary),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: SkotiqTypography.labelQuiet.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
