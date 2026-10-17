import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// See note in hardware_preset_editor_dialog.dart: the hardware-presets provider
// and its service live outside the skotiq_core barrel (the C5 owner avoided
// a `cameraPresetsProvider` name collision by keeping them package-private), so
// import the source paths directly — the precedent set by the provider's own
// test suite.
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hardware_presets/hardware_presets_service.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'hardware_preset_editor_dialog.dart';

/// Searchable, editable hardware library picker.
///
/// Presents the merged built-in + user presets (telescopes or camera defaults)
/// in a scrollable list. Each row selects on tap (returning the preset via
/// `Navigator.pop`). User presets can be edited or deleted in place; built-ins
/// carry a "Built-in" badge and an edit affordance that opens the editor
/// pre-filled to save a user override copy (the catalog stays pristine).
///
/// Use the static [showTelescope] / [showCamera] entry points; the private
/// constructor enforces a valid (kind, providers) pairing.
class HardwarePresetPickerDialog extends ConsumerStatefulWidget {
  final HardwarePresetKind kind;

  const HardwarePresetPickerDialog._({required this.kind});

  /// Opens the telescope library. Resolves to the chosen [TelescopePreset], or
  /// null if the user dismissed the dialog without picking.
  static Future<TelescopePreset?> showTelescope(BuildContext context) {
    return showDialog<TelescopePreset>(
      context: context,
      builder: (_) => const HardwarePresetPickerDialog._(
          kind: HardwarePresetKind.telescope),
    );
  }

  /// Opens the camera library. Resolves to the chosen [CameraDefaultsPreset],
  /// or null if dismissed.
  static Future<CameraDefaultsPreset?> showCamera(BuildContext context) {
    return showDialog<CameraDefaultsPreset>(
      context: context,
      builder: (_) =>
          const HardwarePresetPickerDialog._(kind: HardwarePresetKind.camera),
    );
  }

  @override
  ConsumerState<HardwarePresetPickerDialog> createState() =>
      _HardwarePresetPickerDialogState();
}

class _HardwarePresetPickerDialogState
    extends ConsumerState<HardwarePresetPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  bool get _isTelescope => widget.kind == HardwarePresetKind.telescope;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch the service so the list rebuilds when an edit/delete mutates the
    // override set; the *_presetsProvider convenience providers depend on it.
    final service = ref.watch(hardwarePresetsServiceProvider);

    return SkotiqDialog(
      title: _isTelescope ? 'Telescope library' : 'Camera library',
      icon: _isTelescope ? LucideIcons.orbit : LucideIcons.camera,
      width: 680,
      // The body manages its own scrolling list; do not double-wrap.
      scrollableBody: false,
      actions: [
        SkotiqButton(
          label: 'Add custom',
          icon: LucideIcons.plus,
          variant: ButtonVariant.outline,
          onPressed: _addCustom,
        ),
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: SizedBox(
        // Bound the body so the list scrolls inside the dialog rather than
        // overflowing on tall catalogs.
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SkotiqTextField(
              controller: _searchController,
              hint: _isTelescope
                  ? 'Search by brand or model…'
                  : 'Search by brand, model, or sensor…',
              prefixIcon: LucideIcons.search,
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Expanded(
              child: _isTelescope
                  ? _buildTelescopeList(service)
                  : _buildCameraList(service),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTelescopeList(HardwarePresetsService service) {
    final results = service.searchTelescopes(_query);
    if (results.isEmpty) return _emptyResults();
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: results.length,
      separatorBuilder: (_, __) =>
          const SizedBox(height: SkotiqTokens.spaceSm),
      itemBuilder: (context, index) {
        final preset = results[index];
        return _PresetRow(
          title: preset.displayName,
          spec: _telescopeSpecLine(preset),
          isBuiltIn: preset.isBuiltIn,
          onSelect: () => Navigator.of(context).pop(preset),
          onEdit: () => _editTelescope(preset),
          onDelete: preset.isBuiltIn ? null : () => _deleteTelescope(preset),
        );
      },
    );
  }

  Widget _buildCameraList(HardwarePresetsService service) {
    final results = service.searchCameras(_query);
    if (results.isEmpty) return _emptyResults();
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: results.length,
      separatorBuilder: (_, __) =>
          const SizedBox(height: SkotiqTokens.spaceSm),
      itemBuilder: (context, index) {
        final preset = results[index];
        return _PresetRow(
          title: preset.displayName,
          spec: _cameraSpecLine(preset),
          isBuiltIn: preset.isBuiltIn,
          onSelect: () => Navigator.of(context).pop(preset),
          onEdit: () => _editCamera(preset),
          onDelete: preset.isBuiltIn ? null : () => _deleteCamera(preset),
        );
      },
    );
  }

  Widget _emptyResults() {
    return EmptyState.compact(
      icon: LucideIcons.searchX,
      title: 'No matches',
      body: _query.trim().isEmpty
          ? 'No presets available.'
          : 'No presets match “${_query.trim()}”.',
    );
  }

  /// e.g. `550mm f/5.5 · 100mm refractor`. The marketed [nativeFocalRatio] is
  /// shown when present, otherwise the derived ratio.
  static String _telescopeSpecLine(TelescopePreset preset) {
    final ratio = preset.nativeFocalRatio ?? preset.focalRatio;
    final focalLength =
        preset.focalLengthMm == preset.focalLengthMm.roundToDouble()
            ? preset.focalLengthMm.round().toString()
            : preset.focalLengthMm.toString();
    final aperture = preset.apertureMm == preset.apertureMm.roundToDouble()
        ? preset.apertureMm.round().toString()
        : preset.apertureMm.toString();
    return '${focalLength}mm f/${ratio.toStringAsFixed(1)} · '
        '${aperture}mm ${preset.design.label.toLowerCase()}';
  }

  /// e.g. `3.76µm · IMX571 mono · 6248×4176`.
  static String _cameraSpecLine(CameraDefaultsPreset preset) {
    final pixel =
        preset.pixelSizeMicrons == preset.pixelSizeMicrons.roundToDouble()
            ? preset.pixelSizeMicrons.round().toString()
            : preset.pixelSizeMicrons.toString();
    // Braces kept deliberately: the following 'µ' (micro sign) is a non-ASCII
    // glyph and brace-delimiting the identifier avoids any ambiguity for
    // readers, even though the analyzer parses the bare form unambiguously.
    // ignore: unnecessary_brace_in_string_interps
    return '${pixel}µm · ${preset.sensorName} '
        '${preset.isColor ? 'color' : 'mono'} · '
        '${preset.sensorWidthPx}×${preset.sensorHeightPx}';
  }

  // Mutations. each opens the editor or confirms deletion, surfacing errors.

  Future<void> _addCustom() async {
    if (_isTelescope) {
      final saved = await HardwarePresetEditorDialog.editTelescope(context);
      if (saved != null && mounted) Navigator.of(context).pop(saved);
    } else {
      final saved = await HardwarePresetEditorDialog.editCamera(context);
      if (saved != null && mounted) Navigator.of(context).pop(saved);
    }
  }

  Future<void> _editTelescope(TelescopePreset preset) async {
    // The editor handles its own persistence + error surfacing; we just refresh
    // the list (the watched provider rebuilds automatically on save).
    await HardwarePresetEditorDialog.editTelescope(context, initial: preset);
  }

  Future<void> _editCamera(CameraDefaultsPreset preset) async {
    await HardwarePresetEditorDialog.editCamera(context, initial: preset);
  }

  Future<void> _deleteTelescope(TelescopePreset preset) async {
    final confirmed = await _confirmDelete(preset.displayName);
    if (!confirmed || !mounted) return;
    try {
      await ref
          .read(hardwarePresetsServiceProvider.notifier)
          .deleteTelescopePreset(preset.id);
    } catch (error, stackTrace) {
      if (!mounted) return;
      unawaited(
        ErrorDialog.show(
          context,
          title: 'Could not delete preset',
          message: 'The preset “${preset.displayName}” could not be removed.',
          technicalDetails: '$error\n$stackTrace',
        ),
      );
    }
  }

  Future<void> _deleteCamera(CameraDefaultsPreset preset) async {
    final confirmed = await _confirmDelete(preset.displayName);
    if (!confirmed || !mounted) return;
    try {
      await ref
          .read(hardwarePresetsServiceProvider.notifier)
          .deleteCameraPreset(preset.id);
    } catch (error, stackTrace) {
      if (!mounted) return;
      unawaited(
        ErrorDialog.show(
          context,
          title: 'Could not delete preset',
          message: 'The preset “${preset.displayName}” could not be removed.',
          technicalDetails: '$error\n$stackTrace',
        ),
      );
    }
  }

  Future<bool> _confirmDelete(String displayName) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SkotiqDialog(
        title: 'Delete preset',
        icon: LucideIcons.trash2,
        width: 440,
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          SkotiqButton(
            label: 'Delete',
            icon: LucideIcons.trash2,
            variant: ButtonVariant.destructive,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
        child: Text(
          'Remove “$displayName” from your library? This cannot be undone.',
          style: SkotiqTypography.body.copyWith(
            color: SkotiqColors.of(dialogContext).textSecondary,
          ),
        ),
      ),
    );
    return result ?? false;
  }
}

/// A single selectable preset row: a tappable [SkotiqCard] with the display
/// name, a monospace spec line, an optional "Built-in" badge, and edit/delete
/// affordances.
class _PresetRow extends StatelessWidget {
  final String title;
  final String spec;
  final bool isBuiltIn;
  final VoidCallback onSelect;
  final VoidCallback onEdit;

  /// Null for built-ins, which cannot be deleted.
  final VoidCallback? onDelete;

  const _PresetRow({
    required this.title,
    required this.spec,
    required this.isBuiltIn,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return SkotiqCard(
      onTap: onSelect,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceMd,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: SkotiqTypography.bodyMedium
                            .copyWith(color: colors.textPrimary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isBuiltIn) ...[
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      _builtInBadge(colors),
                    ],
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  spec,
                  style: SkotiqTypography.monoSm
                      .copyWith(color: colors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          AccessibleIconButton(
            icon: LucideIcons.pencil,
            label: isBuiltIn ? 'Copy and edit $title' : 'Edit $title',
            tooltip: isBuiltIn ? 'Create an editable copy' : 'Edit this preset',
            color: colors.textSecondary,
            size: SkotiqTokens.iconSm,
            onPressed: onEdit,
          ),
          if (onDelete != null)
            AccessibleIconButton(
              icon: LucideIcons.trash2,
              label: 'Delete $title',
              tooltip: 'Delete this preset',
              color: colors.error,
              size: SkotiqTokens.iconSm,
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }

  Widget _builtInBadge(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: 2,
      ),
      decoration: SkotiqDecorations.tintedBadge(
        colors.info,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: Text(
        'Built-in',
        style: SkotiqTypography.labelQuiet.copyWith(color: colors.info),
      ),
    );
  }
}
