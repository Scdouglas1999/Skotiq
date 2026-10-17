part of '../object_info_popup.dart';

// NOTE (design tokens): the `Colors.white*` literals below are canvas-absolute
// HUD colors for the object popup drawn over the planetarium sky (red-adapted by
// the enclosing `_NightVisionFilter`), intentionally not theme-relative — see
// the note in the parent library file.

/// Slew popup menu button for planetarium object popup
class SlewPopupMenuButton extends StatefulWidget {
  final SkotiqColors colors;
  final VoidCallback onSlew;
  final VoidCallback onSlewAndCenter;
  final VoidCallback onSlewCenterRotate;
  final bool showRotateOption;

  const SlewPopupMenuButton({
    super.key,
    required this.colors,
    required this.onSlew,
    required this.onSlewAndCenter,
    required this.onSlewCenterRotate,
    required this.showRotateOption,
  });

  @override
  State<SlewPopupMenuButton> createState() => _SlewPopupMenuButtonState();
}

class _SlewPopupMenuButtonState extends State<SlewPopupMenuButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    return PopupMenuButton<SlewMode>(
      onSelected: (mode) {
        switch (mode) {
          case SlewMode.slew:
            widget.onSlew();
            break;
          case SlewMode.slewAndCenter:
            widget.onSlewAndCenter();
            break;
          case SlewMode.slewCenterRotate:
            widget.onSlewCenterRotate();
            break;
        }
      },
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
      color: widget.colors.surface,
      itemBuilder: (context) => [
        PopupMenuItem<SlewMode>(
          value: SlewMode.slew,
          child: Row(
            children: [
              Icon(SkotiqIcons.move,
                  size: 16, color: widget.colors.textPrimary),
              const SizedBox(width: 8),
              Text('Slew', style: TextStyle(color: widget.colors.textPrimary)),
            ],
          ),
        ),
        PopupMenuItem<SlewMode>(
          value: SlewMode.slewAndCenter,
          child: Row(
            children: [
              Icon(SkotiqIcons.target,
                  size: 16, color: widget.colors.textPrimary),
              const SizedBox(width: 8),
              Text('Slew & Center',
                  style: TextStyle(color: widget.colors.textPrimary)),
            ],
          ),
        ),
        if (widget.showRotateOption)
          PopupMenuItem<SlewMode>(
            value: SlewMode.slewCenterRotate,
            child: Row(
              children: [
                Icon(LucideIcons.rotateCw,
                    size: 16, color: widget.colors.textPrimary),
                const SizedBox(width: 8),
                Text('Slew, Center & Rotate',
                    style: TextStyle(color: widget.colors.textPrimary)),
              ],
            ),
          ),
      ],
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            color: _isHovered
                ? widget.colors.primary.withValues(alpha: 0.92)
                : widget.colors.primary,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: widget.colors.primary.withValues(alpha: 0.85),
            ),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  SkotiqIcons.crosshair,
                  size: 14,
                  color: onPrimary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Slew',
                  style: SkotiqTypography.h6.copyWith(color: onPrimary),
                ),
                const SizedBox(width: 4),
                Icon(
                  SkotiqIcons.chevronDown,
                  size: 12,
                  color: onPrimary.withValues(alpha: 0.8),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PopupInfoChip extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const PopupInfoChip({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: SkotiqTypography.fontSize9,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: SkotiqTypography.labelQuiet.copyWith(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class PopupCoordRow extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const PopupCoordRow({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          '$label: ',
          style: const TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: Colors.white38,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class PopupActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final SkotiqColors colors;
  final bool isPrimary;
  final VoidCallback onTap;

  const PopupActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.colors,
    this.isPrimary = false,
    required this.onTap,
  });

  @override
  State<PopupActionButton> createState() => _PopupActionButtonState();
}

class _PopupActionButtonState extends State<PopupActionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            color: widget.isPrimary
                ? (_isHovered
                    ? widget.colors.primary.withValues(alpha: 0.92)
                    : widget.colors.primary)
                : _isHovered
                    ? widget.colors.surfaceHover
                    : widget.colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: widget.isPrimary
                  ? widget.colors.primary.withValues(alpha: 0.85)
                  : (_isHovered
                      ? widget.colors.primary.withValues(alpha: 0.5)
                      : widget.colors.border),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 14,
                color:
                    widget.isPrimary ? onPrimary : widget.colors.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: SkotiqTypography.labelQuiet.copyWith(
                      color: widget.isPrimary
                          ? onPrimary
                          : widget.colors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dialog for adding a celestial object to an observing list.
class _AddToListDialog extends ConsumerStatefulWidget {
  final CelestialObject object;
  final CelestialCoordinate coordinates;

  const _AddToListDialog({
    required this.object,
    required this.coordinates,
  });

  @override
  ConsumerState<_AddToListDialog> createState() => _AddToListDialogState();
}

class _AddToListDialogState extends ConsumerState<_AddToListDialog> {
  final _newListNameController = TextEditingController();
  bool _creatingNew = false;

  @override
  void dispose() {
    _newListNameController.dispose();
    super.dispose();
  }

  String get _objectName {
    final obj = widget.object;
    if (obj is DeepSkyObject) {
      return getDsoDisplayInfo(obj).$1;
    }
    return obj.name;
  }

  String? get _catalogId {
    final obj = widget.object;
    if (obj is DeepSkyObject) {
      // Prefer Messier, then NGC/IC, then id
      if (obj.isMessier && obj.messierNumber != null) return obj.messierNumber;
      if (obj.ngcIcDesignation != null) return obj.ngcIcDesignation;
      return obj.id;
    }
    return obj.id;
  }

  String? get _objectType {
    final obj = widget.object;
    if (obj is DeepSkyObject) return obj.type.displayName;
    if (obj is SolarSystemBody) return obj.kind.displayName;
    if (obj is Star) return 'Star';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final listsAsync = ref.watch(observingListsProvider);

    return AlertDialog(
      title: Text('Add "$_objectName" to List'),
      content: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 300,
        ),
        child: listsAsync.when(
          data: (lists) {
            if (lists.isEmpty && !_creatingNew) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('No observing lists yet. Create one first.'),
                  const SizedBox(height: 16),
                  _buildNewListField(),
                ],
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (lists.isNotEmpty) ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: math.min(
                        200,
                        MediaQuery.sizeOf(context).height * 0.25,
                      ),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: lists.length,
                      itemBuilder: (context, index) {
                        final list = lists[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(SkotiqIcons.list, size: 18),
                          title: Text(list.name),
                          onTap: () => _addToList(list.id),
                        );
                      },
                    ),
                  ),
                  const Divider(),
                ],
                if (_creatingNew)
                  _buildNewListField()
                else
                  TextButton.icon(
                    onPressed: () => setState(() => _creatingNew = true),
                    icon: const Icon(SkotiqIcons.add, size: 16),
                    label: const Text('Create New List'),
                  ),
              ],
            );
          },
          loading: () => const SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          error: (e, _) => Text('Error loading lists: $e'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_creatingNew)
          FilledButton(
            onPressed: _createAndAdd,
            child: const Text('Create & Add'),
          ),
      ],
    );
  }

  Widget _buildNewListField() {
    return TextField(
      controller: _newListNameController,
      decoration: const InputDecoration(
        labelText: 'New List Name',
        hintText: 'e.g., Winter Galaxies',
      ),
      autofocus: true,
      onSubmitted: (_) => _createAndAdd(),
    );
  }

  Future<void> _addToList(int listId) async {
    final notifier = ref.read(observingListNotifierProvider.notifier);
    final id = await notifier.addItem(
      listId: listId,
      objectName: _objectName,
      catalogId: _catalogId,
      objectType: _objectType,
      ra: widget.coordinates.ra,
      dec: widget.coordinates.dec,
      magnitude: widget.object.magnitude,
      sizeArcmin: widget.object is DeepSkyObject
          ? (widget.object as DeepSkyObject).sizeArcMin
          : null,
    );

    if (mounted) {
      Navigator.of(context).pop();
      final uiState = ref.read(observingListNotifierProvider);
      if (id != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added $_objectName to list')),
        );
      } else if (uiState.errorMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(uiState.errorMessage!)),
        );
      } else if (uiState.statusMessage != null) {
        // No row written and no error: the benign "already in this list"
        // outcome. Say so instead of closing silently.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(uiState.statusMessage!)),
        );
      }
    }
  }

  Future<void> _createAndAdd() async {
    final name = _newListNameController.text.trim();
    if (name.isEmpty) return;

    final notifier = ref.read(observingListNotifierProvider.notifier);
    final listId = await notifier.createList(name: name);
    if (listId == null) {
      if (mounted) {
        final uiState = ref.read(observingListNotifierProvider);
        if (uiState.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(uiState.errorMessage!)),
          );
        }
      }
      return;
    }

    await _addToList(listId);
  }
}
