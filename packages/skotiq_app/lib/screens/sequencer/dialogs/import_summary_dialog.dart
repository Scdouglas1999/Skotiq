import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What the user chose to do with an imported sequence once they've reviewed
/// the parse summary.
enum ImportDestination {
  /// Persist into the sequences table via [SequenceRepository] and show a
  /// confirmation SnackBar. Does NOT load the sequence into the editor;
  /// the user can browse to it from the library tab.
  saveToLibrary,

  /// Persist into the library AND load the imported sequence into the editor
  /// so the user can immediately work with it.
  openInEditor,
}

/// Decision the user made in the dialog. `null` `destination` means the user
/// cancelled.
class ImportSummaryDecision {
  final ImportDestination? destination;
  final String sequenceName;

  const ImportSummaryDecision({
    required this.destination,
    required this.sequenceName,
  });

  bool get cancelled => destination == null;
}

/// Post-parse summary dialog. Shows what was found in the source file, what
/// got dropped/unsupported, and lets the user pick where the imported
/// sequence should land.
class ImportSummaryDialog extends StatefulWidget {
  final ImportResult result;

  const ImportSummaryDialog({super.key, required this.result});

  @override
  State<ImportSummaryDialog> createState() => _ImportSummaryDialogState();

  /// Convenience for callers: show the dialog and await its
  /// [ImportSummaryDecision].
  static Future<ImportSummaryDecision?> show(
    BuildContext context, {
    required ImportResult result,
  }) {
    return showDialog<ImportSummaryDecision>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ImportSummaryDialog(result: result),
    );
  }
}

class _ImportSummaryDialogState extends State<ImportSummaryDialog> {
  late TextEditingController _nameController;
  ImportDestination _destination = ImportDestination.openInEditor;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.result.sequence.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final result = widget.result;
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 640,
      designHeight: 720,
    );
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(colors: colors, result: result),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _NameField(
                      controller: _nameController,
                      colors: colors,
                    ),
                    const SizedBox(height: 16),
                    _OverviewRow(colors: colors, result: result),
                    const SizedBox(height: 16),
                    _MappingTable(colors: colors, rows: result.mappingTable),
                    if (result.droppedNodes.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _DroppedSection(
                          colors: colors, dropped: result.droppedNodes),
                    ],
                    if (result.unsupportedNodes.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _UnsupportedSection(
                          colors: colors,
                          unsupported: result.unsupportedNodes,
                          forced: result.forcedImport),
                    ],
                    const SizedBox(height: 16),
                    _DestinationPicker(
                      colors: colors,
                      destination: _destination,
                      onChanged: (d) => setState(() => _destination = d),
                    ),
                  ],
                ),
              ),
            ),
            _Footer(
              colors: colors,
              onCancel: () => Navigator.of(context).pop(
                  const ImportSummaryDecision(
                      destination: null, sequenceName: '')),
              onImport: () {
                Navigator.of(context).pop(ImportSummaryDecision(
                  destination: _destination,
                  sequenceName: _nameController.text.trim().isEmpty
                      ? widget.result.sequence.name
                      : _nameController.text.trim(),
                ));
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final SkotiqColors colors;
  final ImportResult result;
  const _Header({required this.colors, required this.result});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.fileInput, size: 20, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Import Sequence — ${result.sourceFormat.displayName}',
                  style:
                      SkotiqTypography.h4.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  '${result.totalNodes} source nodes parsed',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted),
                ),
              ],
            ),
          ),
          if (result.forcedImport)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: SkotiqDecorations.statusChip(
                colors.warning,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.alertTriangle,
                      size: 12, color: colors.warning),
                  const SizedBox(width: 4),
                  Text('Force import',
                      style: SkotiqTypography.labelStrongSm
                          .copyWith(color: colors.warning)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _NameField extends StatelessWidget {
  final TextEditingController controller;
  final SkotiqColors colors;
  const _NameField({required this.controller, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sequence name',
            style: SkotiqTypography.h6.copyWith(color: colors.textMuted)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          style: TextStyle(color: colors.textPrimary),
          decoration: InputDecoration(
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                borderSide: BorderSide(color: colors.border)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                borderSide: BorderSide(color: colors.border)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            isDense: true,
          ),
        ),
      ],
    );
  }
}

class _OverviewRow extends StatelessWidget {
  final SkotiqColors colors;
  final ImportResult result;
  const _OverviewRow({required this.colors, required this.result});

  @override
  Widget build(BuildContext context) {
    final mapped = result.mappingTable
        .where((r) => r.skotiqType != null)
        .fold<int>(0, (a, b) => a + b.count);
    return Row(
      children: [
        _Pill(
          label: 'Mapped',
          value: '$mapped',
          color: colors.success,
        ),
        const SizedBox(width: 10),
        _Pill(
          label: 'Dropped',
          value: '${result.droppedNodes.length}',
          color: colors.textMuted,
        ),
        const SizedBox(width: 10),
        _Pill(
          label: 'Unsupported',
          value: '${result.unsupportedNodes.length}',
          color: result.unsupportedNodes.isEmpty
              ? colors.textMuted
              : colors.warning,
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Pill({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: SkotiqDecorations.iconChip(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        borderAlpha: 0.4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: SkotiqTypography.labelStrongSm.copyWith(color: color)),
          const SizedBox(width: 6),
          Text(value,
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize13,
                  color: color,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _MappingTable extends StatelessWidget {
  final SkotiqColors colors;
  final List<MappingTableRow> rows;
  const _MappingTable({required this.colors, required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Text('No mappings were recorded.',
          style: TextStyle(
              fontSize: SkotiqTypography.fontSize12, color: colors.textMuted));
    }
    final headerStyle = TextStyle(
      fontSize: SkotiqTypography.fontSize11,
      color: colors.textMuted,
      fontWeight: FontWeight.w700,
    );
    final cellStyle = TextStyle(
        fontSize: SkotiqTypography.fontSize12, color: colors.textSecondary);
    final droppedCellStyle = cellStyle.copyWith(
      color: colors.textMuted,
      fontStyle: FontStyle.italic,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mapping',
            style: SkotiqTypography.h6.copyWith(color: colors.textMuted)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 30,
              dataRowMinHeight: 28,
              dataRowMaxHeight: 32,
              horizontalMargin: 10,
              columnSpacing: 16,
              columns: [
                DataColumn(label: Text('Source type', style: headerStyle)),
                DataColumn(label: Text('Skotiq type', style: headerStyle)),
                DataColumn(
                  label: Text('Count', style: headerStyle),
                  numeric: true,
                ),
              ],
              rows: [
                for (final r in rows)
                  DataRow(
                    cells: [
                      DataCell(Text(r.sourceType, style: cellStyle)),
                      DataCell(Text(
                        r.skotiqType ?? '<dropped>',
                        style: r.skotiqType == null
                            ? droppedCellStyle
                            : cellStyle.copyWith(color: colors.textPrimary),
                      )),
                      DataCell(Text('${r.count}', style: cellStyle)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DroppedSection extends StatelessWidget {
  final SkotiqColors colors;
  final List<DroppedNodeRecord> dropped;
  const _DroppedSection({required this.colors, required this.dropped});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Dropped (${dropped.length})',
            style: SkotiqTypography.h6.copyWith(color: colors.textMuted)),
        const SizedBox(height: 6),
        for (final d in dropped)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(LucideIcons.x, size: 12, color: colors.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${d.sourceType} — ${d.name} (${_reasonLabel(d.reason)})',
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _reasonLabel(DropReason r) {
    switch (r) {
      case DropReason.decorative:
        return 'non-functional';
      case DropReason.disabled:
        return 'disabled in source';
      case DropReason.unsupported:
        return 'unsupported, forced';
    }
  }
}

class _UnsupportedSection extends StatelessWidget {
  final SkotiqColors colors;
  final List<UnsupportedNodeRecord> unsupported;
  final bool forced;
  const _UnsupportedSection({
    required this.colors,
    required this.unsupported,
    required this.forced,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Unsupported nodes (${unsupported.length})',
          subtitle: forced
              ? 'These were skipped because force-import was requested. '
                  'Your sequence will run without them.'
              : 'These would have aborted the import in strict mode.',
        ),
        const SizedBox(height: 8),
        for (final u in unsupported)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('• ${u.sourceType} — ${u.name}',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary)),
          ),
      ],
    );
  }
}

class _DestinationPicker extends StatelessWidget {
  final SkotiqColors colors;
  final ImportDestination destination;
  final ValueChanged<ImportDestination> onChanged;
  const _DestinationPicker({
    required this.colors,
    required this.destination,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return RadioGroup<ImportDestination>(
      groupValue: destination,
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('After import',
              style: SkotiqTypography.h6.copyWith(color: colors.textMuted)),
          const SizedBox(height: 6),
          RadioListTile<ImportDestination>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: ImportDestination.openInEditor,
            title: Text('Open in editor (save + load)',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    color: colors.textPrimary)),
          ),
          RadioListTile<ImportDestination>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: ImportDestination.saveToLibrary,
            title: Text('Save to library (do not open)',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    color: colors.textPrimary)),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final SkotiqColors colors;
  final VoidCallback onCancel;
  final VoidCallback onImport;
  const _Footer({
    required this.colors,
    required this.onCancel,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: onCancel,
            child: Text('Cancel', style: TextStyle(color: colors.textMuted)),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: onImport,
            icon: const Icon(LucideIcons.check, size: 14),
            label: const Text('Import'),
          ),
        ],
      ),
    );
  }
}
