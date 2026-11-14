import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The two ways to make the mount's position trustworthy again: the operator
/// puts it at home and says so, or Skotiq plate solves a frame and, once the
/// operator accepts the result, syncs the mount to it.
class MountGuardRecoveryDialog extends ConsumerStatefulWidget {
  const MountGuardRecoveryDialog({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<MountGuardRecoveryDialog> createState() =>
      _MountGuardRecoveryDialogState();
}

enum _Step { choose, solving, solved, syncing, done }

class _MountGuardRecoveryDialogState
    extends ConsumerState<MountGuardRecoveryDialog> {
  _Step _step = _Step.choose;
  MountGuardSolveResult? _solve;
  String? _error;
  String _doneText = '';

  Future<void> _confirmHome() async {
    setState(() => _error = null);
    try {
      await ref
          .read(mountGuardProvider.notifier)
          .confirmRehomed(widget.deviceId);
      setState(() {
        _step = _Step.done;
        _doneText =
            'The mount position is trusted again. Skotiq treats the mount as '
            'being at its home position.';
      });
    } catch (e) {
      setState(() => _error = userFacingError(e));
    }
  }

  Future<void> _takeAndSolve() async {
    setState(() {
      _step = _Step.solving;
      _error = null;
    });
    try {
      final solve =
          await ref.read(mountGuardProvider.notifier).solve(widget.deviceId);
      setState(() {
        _solve = solve;
        _step = _Step.solved;
      });
    } catch (e) {
      setState(() {
        _step = _Step.choose;
        _error = userFacingError(e);
      });
    }
  }

  Future<void> _sync() async {
    final solve = _solve;
    if (solve == null) return;
    setState(() {
      _step = _Step.syncing;
      _error = null;
    });
    try {
      await ref
          .read(mountGuardProvider.notifier)
          .recoverySync(widget.deviceId, solve.raHours, solve.decDegrees);
      setState(() {
        _step = _Step.done;
        _doneText =
            'The mount was synced to the plate solve and its position is '
            'trusted again.';
      });
    } catch (e) {
      setState(() {
        _step = _Step.solved;
        _error = userFacingError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final body = TextStyle(
      fontSize: SkotiqTypography.fontSize13,
      color: colors.textSecondary,
    );
    final heading = TextStyle(
      fontSize: SkotiqTypography.fontSize13,
      fontWeight: FontWeight.w700,
      color: colors.textPrimary,
    );

    final List<Widget> children;
    final List<Widget> actions;
    switch (_step) {
      case _Step.choose:
        children = [
          Text(
            'Skotiq will not slew, park, home or flip this mount until its '
            'position is trusted again. Pick one way to recover it.',
            style: body,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text('Put it at home', style: heading),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'Move the mount to its home position (counterweights down, tube '
            "on the pole) by hand or with the mount's own software, then "
            'confirm. Only confirm once it is really there: Skotiq takes your '
            'word for it.',
            style: body,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'It is at home',
              icon: LucideIcons.home,
              variant: ButtonVariant.secondary,
              onPressed: _confirmHome,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text('Plate solve where it points', style: heading),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'Skotiq takes a 5 s frame with the imaging camera and solves it '
            'without using the mount position. You see the result before '
            'anything is synced. The sky must be clear where the telescope '
            'points.',
            style: body,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'Take a frame and solve',
              icon: LucideIcons.camera,
              variant: ButtonVariant.primary,
              onPressed: _takeAndSolve,
            ),
          ),
        ];
        actions = [
          SkotiqButton(
            label: 'Close',
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ];
      case _Step.solving:
      case _Step.syncing:
        children = [
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Text(
                _step == _Step.solving
                    ? 'Taking a frame and plate solving it...'
                    : 'Syncing the mount...',
                style: body,
              ),
            ],
          ),
        ];
        actions = const [];
      case _Step.solved:
        final s = _solve!;
        children = [
          Text('The frame solved.', style: heading),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _row('Telescope points at', _radec(s.raHours, s.decDegrees), body),
          _row(
            'Mount says it points at',
            _radec(s.mountRaHours, s.mountDecDegrees),
            body,
          ),
          _row(
            'Difference',
            '${s.separationDegrees.toStringAsFixed(1)} degrees',
            body,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            'Syncing tells the mount it points where the solve says. After '
            'that its position is trusted again and a held run can be '
            'resumed; it centers on its target before the next frame.',
            style: body,
          ),
        ];
        actions = [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
          SkotiqButton(
            label: 'Sync to this position',
            icon: LucideIcons.crosshair,
            onPressed: _sync,
          ),
        ];
      case _Step.done:
        children = [
          Text(_doneText, style: body),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'A paused run stays paused. Resume it from Tonight when you are '
            'ready; it centers on its target before the next frame.',
            style: body,
          ),
        ];
        actions = [
          SkotiqButton(
            label: 'Done',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ];
    }

    return SkotiqDialog(
      title: 'Recover the mount position',
      icon: LucideIcons.crosshair,
      width: SkotiqDialog.widthForm,
      onClose: () => Navigator.of(context).pop(),
      actions: actions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...children,
          if (_error != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              _error!,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value, TextStyle style) => Padding(
        padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
        child: Row(
          children: [
            SizedBox(width: 190, child: Text(label, style: style)),
            Expanded(
              child: Text(
                value,
                style: style.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ],
        ),
      );
}

String _radec(double raHours, double decDegrees) =>
    'RA ${CoordinateFormat.raDense(raHours)}, '
    'Dec ${CoordinateFormat.decCompact(decDegrees)}';
