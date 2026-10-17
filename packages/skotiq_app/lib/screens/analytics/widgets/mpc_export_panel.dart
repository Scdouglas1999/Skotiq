import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/exported_file_reveal.dart';
import '../../../utils/snackbar_helper.dart';

/// Panel for selecting moving object observations and exporting them
/// in MPC 80-column format for asteroid astrometry submissions.
class MpcExportPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final List<MovingObjectCandidateRow> candidates;

  const MpcExportPanel({
    super.key,
    required this.colors,
    required this.candidates,
  });

  @override
  ConsumerState<MpcExportPanel> createState() => _MpcExportPanelState();
}

class _MpcExportPanelState extends ConsumerState<MpcExportPanel> {
  final Set<int> _selectedIds = {};
  bool _isExporting = false;
  String? _lastExportPath;

  @override
  Widget build(BuildContext context) {
    if (widget.candidates.isEmpty) {
      return const SizedBox.shrink();
    }

    final scienceSettingsAsync = ref.watch(scienceSettingsProvider);
    if (scienceSettingsAsync.hasError || !scienceSettingsAsync.hasValue) {
      return SkotiqPanel(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              scienceSettingsAsync.hasError
                  ? 'MPC reporting settings unavailable'
                  : 'Loading MPC reporting settings…',
              style: SkotiqTypography.body
                  .copyWith(color: widget.colors.error),
            ),
            if (scienceSettingsAsync.hasError) ...[
              const SizedBox(height: 6),
              Text(
                scienceSettingsAsync.error.toString(),
                style: SkotiqTypography.body
                    .copyWith(color: widget.colors.textMuted),
              ),
              const SizedBox(height: 10),
              SkotiqButton(
                label: 'Retry MPC settings',
                icon: LucideIcons.refreshCw,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () => ref.invalidate(scienceSettingsProvider),
              ),
            ],
          ],
        ),
      );
    }
    final scienceSettings = scienceSettingsAsync.requireValue;
    final obsCode = scienceSettings.mpcObservatoryCode;
    final hasObsCode = obsCode.length == 3;

    // Build observation groups for display
    final groups = buildObservationGroups(widget.candidates);

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'MPC Report Export',
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: widget.colors.textPrimary),
                ),
              ),
              if (_selectedIds.isNotEmpty)
                Text(
                  '${_selectedIds.length} selected',
                  style: SkotiqTypography.caption.copyWith(
                      color: widget.colors.primary,
                      fontWeight: FontWeight.w500),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Select observations to include in MPC 80-column format report',
            style: SkotiqTypography.caption
                .copyWith(color: widget.colors.textMuted),
          ),
          const SizedBox(height: 8),

          if (!hasObsCode) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: widget.colors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                border: Border.all(
                  color: widget.colors.error.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.alertTriangle,
                    size: 14,
                    color: widget.colors.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Set your 3-character MPC observatory code in '
                      'Settings > Science > MPC before exporting.',
                      style: SkotiqTypography.caption
                          .copyWith(color: widget.colors.error),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],

          // Select All / Deselect All controls
          Row(
            children: [
              _SmallActionButton(
                colors: widget.colors,
                label: 'Select all',
                onPressed: () {
                  setState(() {
                    _selectedIds.clear();
                    for (final c in widget.candidates) {
                      _selectedIds.add(c.id);
                    }
                  });
                },
              ),
              const SizedBox(width: 8),
              _SmallActionButton(
                colors: widget.colors,
                label: 'Clear',
                onPressed: _selectedIds.isEmpty
                    ? null
                    : () {
                        setState(() => _selectedIds.clear());
                      },
              ),
              const Spacer(),
              _SmallActionButton(
                colors: widget.colors,
                label: 'Multi-night only',
                onPressed: () {
                  setState(() {
                    _selectedIds.clear();
                    for (final group in groups) {
                      if (group.nightCount > 1) {
                        for (final obs in group.observations) {
                          _selectedIds.add(obs.id);
                        }
                      }
                    }
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Observation groups list
          ...groups.map((group) => _ObservationGroupTile(
                colors: widget.colors,
                group: group,
                selectedIds: _selectedIds,
                onToggleGroup: () => _toggleGroup(group),
                onToggleObservation: (id) => _toggleObservation(id),
              )),

          const SizedBox(height: 8),

          // Export actions
          Row(
            children: [
              Expanded(
                child: SkotiqButton(
                  label: _isExporting ? 'Exporting...' : 'Export to File',
                  icon: LucideIcons.download,
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                  onPressed:
                      (_isExporting || _selectedIds.isEmpty || !hasObsCode)
                          ? null
                          : () => _exportToFile(obsCode),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SkotiqButton(
                  label: 'Copy to Clipboard',
                  icon: LucideIcons.clipboard,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: (_selectedIds.isEmpty || !hasObsCode)
                      ? null
                      : () => _copyToClipboard(obsCode),
                ),
              ),
            ],
          ),

          if (_lastExportPath != null) ...[
            const SizedBox(height: 6),
            Text(
              'Exported: $_lastExportPath',
              style: SkotiqTypography.caption
                  .copyWith(color: widget.colors.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  void _toggleGroup(MpcObservationGroup group) {
    setState(() {
      final groupIds = group.observations.map((o) => o.id).toSet();
      final allSelected = groupIds.every(_selectedIds.contains);
      if (allSelected) {
        _selectedIds.removeAll(groupIds);
      } else {
        _selectedIds.addAll(groupIds);
      }
    });
  }

  void _toggleObservation(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  List<MovingObjectCandidateRow> _getSelectedCandidates() {
    return widget.candidates.where((c) => _selectedIds.contains(c.id)).toList();
  }

  Future<void> _exportToFile(String obsCode) async {
    setState(() => _isExporting = true);
    try {
      final service = MpcExportService();
      final selected = _getSelectedCandidates();
      final filePath = await service.exportToFile(
        candidates: selected,
        observatoryCode: obsCode,
      );
      if (mounted) {
        setState(() => _lastExportPath = filePath);
        // MpcExportService writes into resolveSkotiqDocumentsDirectory(),
        // which on Android/iOS is the private sandbox — announcing the path
        // there names a report the observer cannot attach to an MPC
        // submission, so hand the file to the share sheet instead.
        await revealExportedFile(
          context,
          filePath,
          subject: 'MPC observation report',
          desktopMessage: 'MPC report exported to: $filePath',
        );
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('MPC export failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<void> _copyToClipboard(String obsCode) async {
    try {
      final service = MpcExportService();
      final selected = _getSelectedCandidates();
      final report = service.generateReport(
        candidates: selected,
        observatoryCode: obsCode,
      );
      await Clipboard.setData(ClipboardData(text: report));
      if (mounted) {
        context.showSuccessSnackBar(
          'MPC report copied (${selected.length} observations)',
        );
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Copy failed: $e');
      }
    }
  }
}

class _ObservationGroupTile extends StatelessWidget {
  final SkotiqColors colors;
  final MpcObservationGroup group;
  final Set<int> selectedIds;
  final VoidCallback onToggleGroup;
  final void Function(int id) onToggleObservation;

  const _ObservationGroupTile({
    required this.colors,
    required this.group,
    required this.selectedIds,
    required this.onToggleGroup,
    required this.onToggleObservation,
  });

  @override
  Widget build(BuildContext context) {
    final groupIds = group.observations.map((o) => o.id).toSet();
    final selectedCount = groupIds.intersection(selectedIds).length;
    final allSelected = selectedCount == groupIds.length;
    final someSelected = selectedCount > 0 && !allSelected;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 24),
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: SizedBox(
          width: 24,
          height: 24,
          child: Checkbox(
            value: allSelected ? true : (someSelected ? null : false),
            tristate: true,
            onChanged: (_) => onToggleGroup(),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                group.displayName,
                style: SkotiqTypography.bodyStrong.copyWith(
                  color: colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (group.isKnownObject)
              Container(
                margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration:
                    SkotiqDecorations.chip(colors, tone: colors.success),
                child: Text(
                  'Known',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.success),
                ),
              ),
            const SizedBox(width: 8),
            Text(
              '${group.observations.length} obs',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
            if (group.nightCount > 1) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration:
                    SkotiqDecorations.chip(colors, tone: colors.primary),
                child: Text(
                  '${group.nightCount} nights',
                  style: SkotiqTypography.caption.copyWith(
                      color: colors.primary, fontWeight: FontWeight.w500),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Text(
              '${(group.averageConfidence * 100).toStringAsFixed(0)}%',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ],
        ),
        children: group.observations.map((obs) {
          final isSelected = selectedIds.contains(obs.id);
          return Semantics(
              button: true,
              enabled: true,
              selected: isSelected,
              child: InkWell(
                onTap: () => onToggleObservation(obs.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: SkotiqCheckbox(
                          value: isSelected,
                          onChanged: (_) => onToggleObservation(obs.id),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _formatTimestamp(obs.timestamp),
                          style: SkotiqTypography.monoCaption
                              .copyWith(color: colors.textSecondary),
                        ),
                      ),
                      Text(
                        _formatRaBrief(obs.raDegrees),
                        style: SkotiqTypography.monoCaption
                            .copyWith(color: colors.textMuted),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatDecBrief(obs.decDegrees),
                        style: SkotiqTypography.monoCaption
                            .copyWith(color: colors.textMuted),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${obs.motionArcsecPerMinute.toStringAsFixed(1)}"/m',
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
              ));
        }).toList(),
      ),
    );
  }

  String _formatTimestamp(DateTime ts) {
    final utc = ts.toUtc();
    return '${utc.year}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')} '
        '${utc.hour.toString().padLeft(2, '0')}:'
        '${utc.minute.toString().padLeft(2, '0')} UTC';
  }

  String _formatRaBrief(double raDeg) => CoordinateFormat.raFromDegrees(
        raDeg,
        style: SexagesimalStyle.compactLetters,
        seconds: SecondsPrecision.oneDecimalPadded,
      );

  String _formatDecBrief(double decDeg) {
    final sign = decDeg < 0 ? '-' : '+';
    final abs = decDeg.abs();
    final d = abs.floor();
    final m = ((abs - d) * 60.0).floor();
    final s = (((abs - d) * 60.0 - m) * 60.0);
    return '$sign${d.toString().padLeft(2, '0')}d'
        '${m.toString().padLeft(2, '0')}\''
        '${s.toStringAsFixed(0).padLeft(2, '0')}"';
  }
}

class _SmallActionButton extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final VoidCallback? onPressed;

  const _SmallActionButton({
    required this.colors,
    required this.label,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final isDisabled = onPressed == null;
    return Semantics(
        button: true,
        enabled: onPressed != null,
        child: GestureDetector(
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color:
                  isDisabled ? colors.well.withValues(alpha: 0.5) : colors.well,
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline4),
              border: Border.all(
                color: isDisabled
                    ? colors.border.withValues(alpha: 0.3)
                    : colors.border,
              ),
            ),
            child: Text(
              label,
              style: SkotiqTypography.caption.copyWith(
                  color: isDisabled ? colors.textMuted : colors.textSecondary,
                  fontWeight: FontWeight.w500),
            ),
          ),
        ));
  }
}
