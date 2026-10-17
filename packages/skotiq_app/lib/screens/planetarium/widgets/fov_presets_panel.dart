import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../accessible_dropdown.dart';
import 'sidebar_shared_widgets.dart';

/// Schematic colors offered for FOV framing overlays. High-contrast hues that
/// read cleanly over the dark sky canvas and stay distinct when several rigs
/// are shown at once.
const List<Color> _kPresetColors = [
  Color(0xFF00E676), // green
  Color(0xFF42A5F5), // blue
  Color(0xFFFFB300), // amber
  Color(0xFFFF5252), // red
  Color(0xFFAB47BC), // purple
  Color(0xFF26C6DA), // cyan
];

/// Manager for multi-rig FOV framing presets shown on the planetarium sky.
///
/// Lists each preset (with FOV / image-scale readout, visibility toggle and
/// delete), lets the user add one from the bundled telescope + camera catalog,
/// and edits the active preset's position angle and sky anchor (snap to the
/// selected target / un-pin to follow the view). Edits flow through
/// [fovPresetsProvider]; the host screen persists them.
class FovPresetsPanel extends ConsumerWidget {
  final SkotiqColors colors;

  /// The currently selected sky target, used for "snap to target".
  final SelectedObjectState selectedObject;

  const FovPresetsPanel({
    super.key,
    required this.colors,
    required this.selectedObject,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(fovPresetsProvider);
    final notifier = ref.read(fovPresetsProvider.notifier);

    return InfoCard(
      title: 'FOV Framing',
      icon: SkotiqIcons.frame,
      color: colors.accent,
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.presets.isEmpty)
            Text(
              'Add a rig to overlay its sensor field of view on the sky. '
              'Show several at once, drag to reposition and rotate to set the '
              'camera angle.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textSecondary,
              ),
            )
          else
            for (final preset in state.presets)
              _PresetRow(
                preset: preset,
                isActive: preset.id == state.activeId,
                colors: colors,
                onSelect: () => notifier.setActive(preset.id),
                onToggleVisible: () => notifier.toggleVisible(preset.id),
                onDelete: () => notifier.remove(preset.id),
              ),
          if (state.active != null) ...[
            const SizedBox(height: 12),
            _ActivePresetControls(
              preset: state.active!,
              colors: colors,
              selectedObject: selectedObject,
              onRotate: notifier.setActivePositionAngle,
              onSnapToTarget: () {
                final coords = selectedObject.coordinates ??
                    selectedObject.object?.coordinates;
                if (coords != null) notifier.setActiveCenter(coords);
              },
              onUnpin: notifier.clearActiveCenter,
            ),
          ],
          const SizedBox(height: 12),
          SkotiqButton(
            label: 'Add rig',
            icon: SkotiqIcons.add,
            variant: ButtonVariant.outline,
            size: ButtonSize.small,
            onPressed: () => _showAddRigSheet(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddRigSheet(BuildContext context, WidgetRef ref) async {
    final existing = ref.read(fovPresetsProvider).presets.length;
    // Seed the dialog from the rig that is actually connected so the common
    // case ("overlay MY scope") needs no dropdown work at all. Either half may
    // be null (no profile / no connected camera); the dialog then falls back to
    // the bundled catalog for that half only.
    final config = ref.read(opticalConfigProvider);
    final result = await showDialog<FovPreset>(
      context: context,
      builder: (context) => _AddRigDialog(
        colors: colors,
        nextColor: _kPresetColors[existing % _kPresetColors.length],
        profileTelescope: telescopeSpecsFromOpticalConfig(config),
        profileCamera: cameraSensorSpecsFromOpticalConfig(config),
      ),
    );
    if (result != null) {
      ref.read(fovPresetsProvider.notifier).add(result);
    }
  }
}

class _PresetRow extends StatelessWidget {
  final FovPreset preset;
  final bool isActive;
  final SkotiqColors colors;
  final VoidCallback onSelect;
  final VoidCallback onToggleVisible;
  final VoidCallback onDelete;

  const _PresetRow({
    required this.preset,
    required this.isActive,
    required this.colors,
    required this.onSelect,
    required this.onToggleVisible,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final fov = preset.fovDegrees;
    final scale = preset.imageScaleArcsecPerPx;
    final summary = fov == null
        ? 'invalid optics'
        : '${fov.$1.toStringAsFixed(2)}° × ${fov.$2.toStringAsFixed(2)}°'
            '${scale == null ? '' : '  ·  ${scale.toStringAsFixed(2)}"/px'}';

    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? preset.color.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(
            color:
                isActive ? preset.color.withValues(alpha: 0.55) : colors.border,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: preset.color,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preset.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  Text(
                    summary,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: preset.visible ? 'Hide on sky' : 'Show on sky',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: Icon(
                preset.visible
                    ? SkotiqIcons.visible
                    : SkotiqIcons.hidden,
                color: preset.visible ? colors.accent : colors.textMuted,
              ),
              onPressed: onToggleVisible,
            ),
            IconButton(
              tooltip: 'Delete preset',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: Icon(SkotiqIcons.delete, color: colors.textMuted),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivePresetControls extends StatelessWidget {
  final FovPreset preset;
  final SkotiqColors colors;
  final SelectedObjectState selectedObject;
  final ValueChanged<double> onRotate;
  final VoidCallback onSnapToTarget;
  final VoidCallback onUnpin;

  const _ActivePresetControls({
    required this.preset,
    required this.colors,
    required this.selectedObject,
    required this.onRotate,
    required this.onSnapToTarget,
    required this.onUnpin,
  });

  @override
  Widget build(BuildContext context) {
    final hasTarget =
        selectedObject.coordinates != null || selectedObject.object != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Position angle',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              '${preset.positionAngleDeg.toStringAsFixed(0)}°',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
        Slider(
          value: preset.positionAngleDeg.clamp(0, 360),
          max: 360,
          divisions: 360,
          activeColor: preset.color,
          onChanged: onRotate,
        ),
        Row(
          children: [
            Expanded(
              child: SkotiqButton(
                label: preset.center == null ? 'Snap to target' : 'Re-snap',
                icon: SkotiqIcons.target,
                variant: ButtonVariant.outline,
                size: ButtonSize.small,
                onPressed: hasTarget ? onSnapToTarget : null,
              ),
            ),
            if (preset.center != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: SkotiqButton(
                  label: 'Follow view',
                  icon: SkotiqIcons.move,
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: onUnpin,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Dialog for composing a new preset from the bundled telescope + camera
/// catalog, with an optional reducer/Barlow multiplier. Shows a live FOV /
/// image-scale preview so the user can confirm the rig before adding it.
///
/// When the active equipment profile can describe the connected rig
/// ([profileTelescope] / [profileCamera]) it is offered as the first, selected
/// entry of the matching dropdown, so "Add Rig" defaults to the user's own gear
/// rather than to an arbitrary catalog entry.
class _AddRigDialog extends StatefulWidget {
  final SkotiqColors colors;
  final Color nextColor;

  /// The active profile's telescope, or null when no profile supplies a focal
  /// length.
  final TelescopeSpecs? profileTelescope;

  /// The connected camera's sensor, or null when no camera has reported one.
  final CameraSensorSpecs? profileCamera;

  const _AddRigDialog({
    required this.colors,
    required this.nextColor,
    this.profileTelescope,
    this.profileCamera,
  });

  @override
  State<_AddRigDialog> createState() => _AddRigDialogState();
}

class _AddRigDialogState extends State<_AddRigDialog> {
  /// Dropdown entries. The profile-derived entry (when present) is prepended so
  /// it is both the default and the top choice; the identical instance is held
  /// in `_telescope` / `_camera` because these spec types use identity
  /// equality, which `DropdownButton.value` matches on.
  late final List<TelescopeSpecs> _telescopes = [
    if (widget.profileTelescope != null) widget.profileTelescope!,
    ...TelescopeSpecs.commonTelescopes,
  ];
  late final List<CameraSensorSpecs> _cameras = [
    if (widget.profileCamera != null) widget.profileCamera!,
    ...CameraSensorSpecs.commonCameras,
  ];

  late TelescopeSpecs _telescope = _telescopes.first;
  late CameraSensorSpecs _camera = _cameras.first;
  double _multiplier = 1.0;

  static const List<(String, double)> _multipliers = [
    ('0.7× reducer', 0.7),
    ('0.8× reducer', 0.8),
    ('Native (1.0×)', 1.0),
    ('1.5× Barlow', 1.5),
    ('2.0× Barlow', 2.0),
  ];

  bool _isFromProfile(Object spec) =>
      identical(spec, widget.profileTelescope) ||
      identical(spec, widget.profileCamera);

  FovPreset _buildPreset() {
    return FovPreset.fromEquipment(
      id: 'fov-${DateTime.now().microsecondsSinceEpoch}',
      camera: _camera,
      telescope: _telescope,
      focalMultiplier: _multiplier,
      color: widget.nextColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final preview = _buildPreset();
    final fov = preview.fovDegrees;
    final scale = preview.imageScaleArcsecPerPx;

    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text('Add FOV Rig', style: TextStyle(color: colors.textPrimary)),
      content: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 360,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label('Telescope', colors),
              AccessibleDropdown<TelescopeSpecs>(
                isExpanded: true,
                value: _telescope,
                dropdownColor: colors.surfaceAlt,
                items: [
                  for (final t in _telescopes)
                    DropdownMenuItem(
                      value: t,
                      child: Text(
                        '${_isFromProfile(t) ? 'My rig — ' : ''}${t.name} · '
                        '${t.focalLengthMm.toStringAsFixed(0)}mm'
                        '${t.apertureMm > 0 ? ' f/${t.focalRatio.toStringAsFixed(1)}' : ''}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textPrimary),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _telescope = v ?? _telescope),
              ),
              const SizedBox(height: 8),
              _label('Camera', colors),
              AccessibleDropdown<CameraSensorSpecs>(
                isExpanded: true,
                value: _camera,
                dropdownColor: colors.surfaceAlt,
                items: [
                  for (final c in _cameras)
                    DropdownMenuItem(
                      value: c,
                      child: Text(
                        '${_isFromProfile(c) ? 'My rig — ' : ''}${c.name} · '
                        '${c.widthMm.toStringAsFixed(1)}×'
                        '${c.heightMm.toStringAsFixed(1)}mm',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textPrimary),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _camera = v ?? _camera),
              ),
              const SizedBox(height: 8),
              _label('Reducer / Barlow', colors),
              AccessibleDropdown<double>(
                isExpanded: true,
                value: _multiplier,
                dropdownColor: colors.surfaceAlt,
                items: [
                  for (final (label, value) in _multipliers)
                    DropdownMenuItem(
                      value: value,
                      child: Text(label,
                          style: TextStyle(color: colors.textPrimary)),
                    ),
                ],
                onChanged: (v) =>
                    setState(() => _multiplier = v ?? _multiplier),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: widget.nextColor.withValues(alpha: 0.08),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  border: Border.all(
                      color: widget.nextColor.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Icon(SkotiqIcons.frame,
                        size: 16, color: widget.nextColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        fov == null
                            ? 'Invalid optics'
                            : '${fov.$1.toStringAsFixed(2)}° × '
                                '${fov.$2.toStringAsFixed(2)}°'
                                '${scale == null ? '' : '   ${scale.toStringAsFixed(2)}"/px'}',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: colors.textSecondary)),
        ),
        SkotiqButton(
          label: 'Add',
          size: ButtonSize.small,
          onPressed: fov == null
              ? null
              : () => Navigator.of(context).pop(_buildPreset()),
        ),
      ],
    );
  }

  Widget _label(String text, SkotiqColors colors) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textSecondary,
          ),
        ),
      );
}
