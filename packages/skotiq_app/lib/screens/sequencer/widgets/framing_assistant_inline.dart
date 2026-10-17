// Inline framing assistant for the sequencer.
//
// Wraps the planetarium's `FramingView` widget in a sequencer-friendly
// modal. The user picks a target from the properties panel, taps
// "Frame target", and gets a full-screen framing view with the
// target's sky context. Rotating the FOV on the assistant writes
// directly back to the selected TargetHeaderNode.rotation.
//
// The dialog activates `equipmentFovBindingProvider`, which keeps the
// planetarium's equipmentFOVProvider fed from the active equipment
// profile / connected camera, so the rendered FOV matches the rig the
// user is about to use. That binding is the single source of truth for
// the overlay; this dialog only overrides the *rotation*.
//
// The "Use current rotator" button reads `rotatorStateProvider` and
// applies the live mechanical angle — useful when the rotator is
// already on-target and the user just wants to lock the sequence to
// what's installed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Public entry point: open the framing assistant for a TargetHeader.
/// Returns the resulting rotation if the user applied a change, or
/// `null` if cancelled.
Future<double?> showFramingAssistantDialog({
  required BuildContext context,
  required WidgetRef ref,
  required TargetHeaderNode target,
}) async {
  // Activate the equipment binding before the dialog opens so the FOV box
  // reflects the user's rig from the first paint. It is idempotent — the
  // planetarium screen activates the same provider — and it keeps tracking
  // profile/camera changes for as long as the container lives.
  ref.read(equipmentFovBindingProvider);

  final initialRotation = target.rotation ?? 0;
  ref
      .read(equipmentFOVProvider.notifier)
      .setRotation(initialRotation.toDouble());

  return showDialog<double?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => FramingAssistantDialog(target: target),
  );
}

class FramingAssistantDialog extends ConsumerStatefulWidget {
  final TargetHeaderNode target;

  const FramingAssistantDialog({super.key, required this.target});

  @override
  ConsumerState<FramingAssistantDialog> createState() =>
      _FramingAssistantDialogState();
}

class _FramingAssistantDialogState
    extends ConsumerState<FramingAssistantDialog> {
  late double _rotation;

  @override
  void initState() {
    super.initState();
    _rotation = widget.target.rotation ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final equipmentFOV = ref.watch(equipmentFOVProvider);
    final fovTuple = equipmentFOV.fov;
    // Sensor geometry only exists once a camera is connected and has reported
    // its capabilities. Say which half of the rig is missing instead of
    // substituting a typical sensor and drawing a framing box the user would
    // reasonably read as measured.
    final config = ref.watch(opticalConfigProvider);
    final missingOptics = fovTuple != null
        ? null
        : (config == null || config.focalLength == null
            ? 'No equipment profile with a focal length — set one in Settings '
                'to size the framing box.'
            : 'No camera connected, so the sensor size is unknown. Connect the '
                'camera to see the real framing box.');

    return SkotiqDialog(
      title: 'Frame target — ${widget.target.targetName}',
      icon: LucideIcons.scanLine,
      width: 900,
      height: 720,
      scrollableBody: false,
      bodyPadding: EdgeInsets.zero,
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(null),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(_rotation),
          icon: SkotiqIcons.check,
          label: 'Apply rotation',
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
        ),
      ],
      child: Row(
        children: [
          SizedBox(
            width: AdaptiveDialogConstraints.clampPanelWidth(
              context,
              designWidth: 260,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ContextCard(
                    colors: colors,
                    target: widget.target,
                    fov: fovTuple,
                    missingOptics: missingOptics,
                  ),
                  const SizedBox(height: 12),
                  _RotationControls(
                    colors: colors,
                    rotation: _rotation,
                    onChanged: (v) {
                      setState(() => _rotation = v);
                      ref.read(equipmentFOVProvider.notifier).setRotation(v);
                    },
                    onUseLiveRotator: () {
                      final rotatorState = ref.read(rotatorStateProvider);
                      final live = rotatorState.position;
                      if (live == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(
                                  'No rotator connected; cannot read live angle.')),
                        );
                        return;
                      }
                      setState(() => _rotation = live);
                      ref.read(equipmentFOVProvider.notifier).setRotation(live);
                    },
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(SkotiqTokens.radiusLg),
                bottomRight: Radius.circular(SkotiqTokens.radiusLg),
              ),
              child: FramingView(
                target: CelestialCoordinate(
                  ra: widget.target.raHours,
                  dec: widget.target.decDegrees,
                ),
                onRotationChanged: (value) {
                  // The framing view drives the planetarium FOV
                  // rotation directly when the user drags the
                  // rotation handle; mirror it into our local state
                  // so the slider stays in sync.
                  setState(() => _rotation = value);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContextCard extends StatelessWidget {
  final SkotiqColors colors;
  final TargetHeaderNode target;
  final (double, double)? fov;

  /// Why the framing box can't be drawn, or null when [fov] is known.
  final String? missingOptics;

  const _ContextCard({
    required this.colors,
    required this.target,
    required this.fov,
    required this.missingOptics,
  });

  @override
  Widget build(BuildContext context) {
    final fovLabel = fov == null
        ? 'Field of view unknown'
        : '${fov!.$1.toStringAsFixed(2)}° × ${fov!.$2.toStringAsFixed(2)}°';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.target, size: 12, color: colors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  target.targetName,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'RA ${target.raHours.toStringAsFixed(4)}h  '
            'Dec ${target.decDegrees.toStringAsFixed(3)}°',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textSecondary,
              fontFamily: 'monospace',
            ),
          ),
          const Divider(height: 14),
          Row(
            children: [
              Icon(LucideIcons.camera, size: 12, color: colors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  fovLabel,
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textSecondary),
                ),
              ),
            ],
          ),
          if (missingOptics != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(LucideIcons.info, size: 11, color: colors.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    missingOptics!,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.warning,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RotationControls extends StatelessWidget {
  final SkotiqColors colors;
  final double rotation;
  final ValueChanged<double> onChanged;
  final VoidCallback onUseLiveRotator;

  const _RotationControls({
    required this.colors,
    required this.rotation,
    required this.onChanged,
    required this.onUseLiveRotator,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(LucideIcons.rotateCw, size: 13, color: colors.textMuted),
              const SizedBox(width: 6),
              Text('Rotation',
                  style:
                      SkotiqTypography.h6.copyWith(color: colors.textPrimary)),
              const Spacer(),
              Text(
                '${rotation.toStringAsFixed(0)}°',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize14,
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          Slider(
            value: rotation.clamp(-180, 180),
            min: -180,
            max: 180,
            divisions: 360,
            onChanged: onChanged,
            activeColor: colors.primary,
          ),
          const SizedBox(height: 4),
          SkotiqButton(
            onPressed: onUseLiveRotator,
            icon: LucideIcons.activity,
            label: 'Use live rotator',
            variant: ButtonVariant.outline,
            size: ButtonSize.small,
          ),
          const SizedBox(height: 6),
          Text(
            'Drag the FOV rotation handle on the sky view to adjust the '
            'framing angle visually.',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize10, color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
