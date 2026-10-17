part of '../focus_model_curve_card.dart';

class _FilterOffsetsStrip extends ConsumerWidget {
  final String profileId;
  final SkotiqColors colors;

  const _FilterOffsetsStrip({
    required this.profileId,
    required this.colors,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offsets = ref.watch(filterOffsetProvider);
    if (offsets.isLoading) {
      return SizedBox(
        height: 28,
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 8),
            Text('Loading filter offsets…',
                style: TextStyle(fontSize: 11, color: colors.textMuted)),
          ],
        ),
      );
    }
    if (offsets.error != null) {
      return Text(
        offsets.error!,
        style: TextStyle(fontSize: 11, color: colors.error),
      );
    }
    if (offsets.offsets.isEmpty) {
      return Text(
        'No filter offsets yet — collect autofocus data on multiple filters '
        'and pick a reference to populate.',
        style: TextStyle(fontSize: 11, color: colors.textMuted),
      );
    }
    final entries = offsets.offsets.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final e = entries[i];
          final isReference = offsets.referenceFilter == e.key;
          return _FilterChip(
            label: e.key,
            offset: e.value,
            isReference: isReference,
            colors: colors,
            onTap: () => _editOffset(context, ref, e.key, e.value),
          );
        },
      ),
    );
  }

  Future<void> _editOffset(
    BuildContext context,
    WidgetRef ref,
    String filterName,
    int currentOffset,
  ) async {
    final authority = ref.read(backendProvider);
    final activeProfileId =
        ref.read(activeEquipmentProfileProvider)?.id.toString();
    final result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _FilterOffsetEditorSheet(
        filterName: filterName,
        currentOffset: currentOffset,
      ),
    );
    if (result == null) return;
    if (!context.mounted) return;
    final currentProfileId =
        ref.read(activeEquipmentProfileProvider)?.id.toString();
    if (!identical(ref.read(backendProvider), authority) ||
        activeProfileId != profileId ||
        currentProfileId != profileId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'The imaging host or profile changed. Offset edit cancelled.'),
        ),
      );
      return;
    }
    if (result == _kSetAsReference) {
      await ref
          .read(filterOffsetProvider.notifier)
          .setReferenceFilter(filterName);
    } else {
      await ref
          .read(filterOffsetProvider.notifier)
          .setFilterOffset(filterName, result);
    }
  }
}

class _FilterOffsetEditorSheet extends StatefulWidget {
  final String filterName;
  final int currentOffset;

  const _FilterOffsetEditorSheet({
    required this.filterName,
    required this.currentOffset,
  });

  @override
  State<_FilterOffsetEditorSheet> createState() =>
      _FilterOffsetEditorSheetState();
}

class _FilterOffsetEditorSheetState extends State<_FilterOffsetEditorSheet> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentOffset.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null) {
      setState(() => _error = 'Enter a whole-number offset');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Edit "${widget.filterName}" offset',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: 'Offset (steps, relative to reference)',
              errorText: _error,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SkotiqButton(
                  label: 'Cancel',
                  variant: ButtonVariant.outline,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SkotiqButton(
                  label: 'Set as reference',
                  variant: ButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(_kSetAsReference),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SkotiqButton(label: 'Save', onPressed: _save),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// Sentinel value returned from the offset-editor sheet to indicate "make this
/// filter the reference"; chosen well outside the legal step range so a real
/// user offset can never collide with it. Using a sentinel keeps the sheet a
/// single bottom modal instead of an additional confirmation dialog.
const int _kSetAsReference = -0x7FFFFFFF;

class _FilterChip extends StatelessWidget {
  final String label;
  final int offset;
  final bool isReference;
  final SkotiqColors colors;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.offset,
    required this.isReference,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colour = isReference ? colors.primary : colors.surfaceAlt;
    final textColour = isReference ? colors.background : colors.textPrimary;
    final sign = offset > 0 ? '+' : '';
    final valueText = isReference ? 'reference' : '$sign$offset steps';
    // The tap lived on a bare gesture wrapper, which publishes an action
    // and no role, so assistive tech read a live control as an inert
    // disabled panel. The flags are only published when given.
    return Semantics(
        button: true,
        enabled: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colour,
              border: Border.all(
                color: isReference ? colors.primary : colors.border,
              ),
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: textColour,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  valueText,
                  style: TextStyle(
                    fontSize: 11,
                    color: isReference
                        ? colors.background.withValues(alpha: 0.8)
                        : colors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ));
  }
}

/// Module-level helper used by `FocusModelCurveCard.onRunAutofocus` to fire
/// the autofocus job in the background. We keep this as a top-level so the
/// import surface in the widget is small (no `dart:async` leak).
void unawaited(Future<void> future) {
  // ignore: unawaited_futures
  future;
}
