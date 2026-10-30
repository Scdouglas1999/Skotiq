// Variable picker widget. Renders an inline `${ }` icon button
// next to a text field; tapping opens a menu of variables grouped by
// category and inserts the chosen one at the current cursor position.
//
// Defaults to the static `interpolationCatalog` in `skotiq_core` which
// mirrors the Rust source-of-truth at
// `native/skotiq_native/sequencer/src/expressions/catalog.rs`. A field
// with a narrower vocabulary passes its own list — see `variables`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A trailing `${ }` icon button that opens a variable picker menu when
/// tapped. Insert into a TextField's `suffixIcon` slot.
///
/// The bound [controller] is used both for cursor-aware insertion and for
/// the preview render shown at the bottom of the popover.
class VariablePickerButton extends StatelessWidget {
  /// Text field controller — the picker rewrites its text + selection
  /// when the user picks a variable.
  final TextEditingController controller;

  /// Whether to use the compact (icon-only) form or the labelled form
  /// (`${} Insert variable`). Compact suits inline trailing icons; the
  /// labelled form suits the small-variant for node-name editors.
  final bool compact;

  /// Tooltip override; defaults to "Insert variable".
  final String? tooltip;

  /// Optional callback fired after a variable is inserted. The parent
  /// widget can rebuild a preview or run validation here.
  final VoidCallback? onChanged;

  /// The vocabulary this field understands. Defaults to the sequencer's
  /// expression catalog.
  ///
  /// Every offered variable MUST be one the bound field's own interpolator
  /// resolves. Offering the sequencer catalog on a surface with a narrower
  /// vocabulary is not a harmless superset: both interpolators pass an unknown
  /// token through literally, so the user picks `${filter}` from a menu and it
  /// is rendered verbatim into the output.
  final List<InterpolationVariable> variables;

  const VariablePickerButton({
    super.key,
    required this.controller,
    this.compact = true,
    this.tooltip,
    this.onChanged,
    this.variables = interpolationCatalog,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return IconButton(
        tooltip: tooltip ?? 'Insert variable',
        icon: const Icon(Icons.code, size: 18),
        onPressed: () => _open(context),
      );
    }
    return TextButton.icon(
      icon: const Icon(Icons.code, size: 16),
      label: const Text(r'${} Insert'),
      onPressed: () => _open(context),
    );
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showDialog<InterpolationVariable>(
      context: context,
      builder: (ctx) => _VariablePickerDialog(
        currentText: controller.text,
        variables: variables,
      ),
    );
    if (picked == null) return;
    _insertAtCursor(picked.placeholder);
    onChanged?.call();
  }

  /// Replace the current selection (or insert at the cursor) with [text],
  /// and place the cursor immediately after the insertion.
  void _insertAtCursor(String text) {
    final selection = controller.selection;
    final current = controller.text;
    // Selection may be invalid (-1) when the field has never received focus.
    final start = selection.start >= 0 ? selection.start : current.length;
    final end = selection.end >= 0 ? selection.end : current.length;
    final next = current.replaceRange(start, end, text);
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }
}

class _VariablePickerDialog extends StatefulWidget {
  final String currentText;
  final List<InterpolationVariable> variables;
  const _VariablePickerDialog({
    required this.currentText,
    required this.variables,
  });

  @override
  State<_VariablePickerDialog> createState() => _VariablePickerDialogState();
}

class _VariablePickerDialogState extends State<_VariablePickerDialog> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _search.isEmpty
        ? widget.variables
        : widget.variables
            .where((v) =>
                v.name.toLowerCase().contains(_search.toLowerCase()) ||
                v.description.toLowerCase().contains(_search.toLowerCase()))
            .toList();

    final grouped = <InterpolationVariableGroup, List<InterpolationVariable>>{};
    for (final v in filtered) {
      grouped.putIfAbsent(v.group, () => []).add(v);
    }

    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 480,
      designHeight: 560,
    );

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.code, size: 20),
          const SizedBox(width: 8),
          const Text('Insert variable'),
          const Spacer(),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      contentPadding:
          const EdgeInsets.only(left: 24, right: 24, top: 8, bottom: 8),
      content: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search variables…',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
            const SizedBox(height: 8),
            if (widget.currentText.contains(r'${'))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.visibility, size: 14, color: theme.hintColor),
                      const SizedBox(width: 6),
                      const Text('Preview:'),
                      const SizedBox(width: 6),
                      Expanded(
                        child: SelectableText(
                          previewInterpolation(
                            widget.currentText,
                            catalog: widget.variables,
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                children: [
                  for (final group in InterpolationVariableGroup.values)
                    if (grouped[group] != null && grouped[group]!.isNotEmpty)
                      _GroupSection(
                        group: group,
                        entries: grouped[group]!,
                        onPick: (v) => Navigator.of(context).pop(v),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupSection extends StatelessWidget {
  final InterpolationVariableGroup group;
  final List<InterpolationVariable> entries;
  final ValueChanged<InterpolationVariable> onPick;

  const _GroupSection({
    required this.group,
    required this.entries,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            group.label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.hintColor,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (final entry in entries) _VariableRow(entry: entry, onPick: onPick),
      ],
    );
  }
}

class _VariableRow extends StatelessWidget {
  final InterpolationVariable entry;
  final ValueChanged<InterpolationVariable> onPick;

  const _VariableRow({required this.entry, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The tap lived on a bare gesture wrapper, which publishes an action
    // and no role, so assistive tech read a live control as an inert
    // disabled panel. The flags are only published when given.
    return Semantics(
        button: true,
        enabled: true,
        child: InkWell(
          onTap: () => onPick(entry),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Why Text (not SelectableText): SelectableText eats the
                      // pointer down event to support selection, which then
                      // suppresses the InkWell's onTap. The placeholder text
                      // is short enough that copy-via-button is sufficient.
                      Text(
                        entry.placeholder,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: SkotiqTypography.fontFamilyMono,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                  ),
                  child: Text(
                    entry.example,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: SkotiqTypography.fontFamilyMono,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Copy ${entry.placeholder}',
                  icon: const Icon(Icons.copy_outlined, size: 14),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: entry.placeholder));
                  },
                ),
              ],
            ),
          ),
        ));
  }
}
