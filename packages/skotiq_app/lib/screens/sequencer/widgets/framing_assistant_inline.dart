// The sequencer's Frame target dialog: the framing sky of Plan > Framing on
// the selected TargetHeaderNode, with a rotation control. It frames on the one
// framing session (framingProvider), so the field of view, survey and
// overlays are the Framing tab's own; Apply writes the session's rotation
// back to the node.
//
// "Use live rotator" reads rotatorStateProvider and applies the live
// mechanical angle, for a rotator already on target.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../utils/snackbar_helper.dart';
import '../../framing/widgets/framing_sky_canvas.dart';

/// Public entry point: open the framing assistant for a TargetHeader.
/// Returns the resulting rotation if the user applied a change, or
/// `null` if cancelled.
Future<double?> showFramingAssistantDialog({
  required BuildContext context,
  required WidgetRef ref,
  required TargetHeaderNode target,
}) async {
  ref.read(framingProvider.notifier)
    ..setTargetCoordinates(
      target.raHours,
      target.decDegrees,
      name: target.targetName,
    )
    ..setRotation((target.rotation ?? 0).toDouble());

  return showDialog<double?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => FramingAssistantDialog(target: target),
  );
}

class FramingAssistantDialog extends ConsumerWidget {
  final TargetHeaderNode target;

  const FramingAssistantDialog({super.key, required this.target});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final rotation = ref.watch(framingProvider.select((s) => s.rotation));
    final equipment = ref.watch(framingFOVProvider).valueOrNull;
    final framing = ref.read(framingProvider.notifier);

    return SkotiqDialog(
      title: 'Frame target — ${target.targetName}',
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
          onPressed: () =>
              Navigator.of(context).pop(ref.read(framingProvider).rotation),
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
                    target: target,
                    equipment: equipment,
                  ),
                  const SizedBox(height: 12),
                  _RotationControls(
                    colors: colors,
                    rotation: rotation,
                    onChanged: framing.setRotation,
                    onUseLiveRotator: () {
                      final live = ref.read(rotatorStateProvider).position;
                      if (live == null) {
                        context.showInfoSnackBar(
                          'No rotator connected; cannot read live angle.',
                        );
                        return;
                      }
                      framing.setRotation(live);
                    },
                  ),
                ],
              ),
            ),
          ),
          const Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.only(
                topRight: Radius.circular(SkotiqTokens.radiusLg),
                bottomRight: Radius.circular(SkotiqTokens.radiusLg),
              ),
              child: FramingSkyCanvas(),
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

  /// The framing session's equipment; null while it loads.
  final FramingEquipmentResult? equipment;

  const _ContextCard({
    required this.colors,
    required this.target,
    required this.equipment,
  });

  @override
  Widget build(BuildContext context) {
    final rig = equipment?.isReady == true ? equipment!.equipment : null;
    final fovLabel = rig == null
        ? 'Field of view unknown'
        : '${rig.fovWidthDeg.toStringAsFixed(2)}° × '
            '${rig.fovHeightDeg.toStringAsFixed(2)}°';
    // Why the framing box can't be drawn, in the framing session's words.
    final missingOptics = rig == null ? equipment?.message : null;
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
              fontFamily: SkotiqTypography.fontFamilyMono,
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
                    missingOptics,
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
                  fontFamily: SkotiqTypography.fontFamilyMono,
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
            'Drag the rotation handle of the frame on the sky to turn it '
            'there instead.',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize10, color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
