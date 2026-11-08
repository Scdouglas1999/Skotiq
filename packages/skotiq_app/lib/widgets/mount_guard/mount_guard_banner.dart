import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'mount_guard_recovery_dialog.dart';

/// A full-width alarm for a mount that moved on its own or whose position
/// Skotiq no longer trusts, with the ways out.
///
/// Shown on Tonight, the Mount panel and Equipment, on the host and on
/// linked clients. Nothing here hides itself: it stays until the operator
/// acknowledges the fault or recovers the position.
class MountGuardBanner extends ConsumerWidget {
  const MountGuardBanner({super.key, this.deviceId});

  /// Only this mount's entry; every mount's when null.
  final String? deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref
        .watch(mountGuardProvider)
        .where((e) => deviceId == null || e.deviceId == deviceId)
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final e in entries) _EntryCard(entry: e)],
    );
  }
}

class _EntryCard extends ConsumerStatefulWidget {
  const _EntryCard({required this.entry});

  final MountGuardEntry entry;

  @override
  ConsumerState<_EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends ConsumerState<_EntryCard> {
  bool _busy = false;
  String? _error;

  Future<void> _acknowledge() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(mountGuardProvider.notifier)
          .acknowledgeFault(widget.entry.deviceId);
    } catch (e) {
      setState(() => _error = mountGuardErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final entry = widget.entry;
    final fault = entry.fault;
    final lost = entry.positionUnknown;
    final stillMoving = fault?.stillMoving == true;
    final runPaused = fault?.runPaused == true || lost?.runPaused == true;

    final title = lost != null
        ? "Mount position unknown: automatic moves are stopped"
        : stillMoving
        ? 'The mount is moving on its own'
        : 'The mount moved on its own';
    final lines = <String>[
      if (fault != null) fault.message,
      if (lost != null) lost.message,
      if (fault != null && fault.stopAttempts.isNotEmpty)
        'Stop commands sent: ${_summarizeAttempts(fault.stopAttempts)}',
      if (stillMoving && fault?.stopAttempts.isNotEmpty == true)
        'It is still moving after every stop command Skotiq has. Stop it at '
            'the mount or cut its power.',
      if (stillMoving && fault?.stopAttempts.isEmpty == true)
        'Skotiq has not tried to stop it: it is not heading below the '
            'horizon, and it may be someone moving the mount from outside '
            'Skotiq.',
      if (runPaused)
        'The run is paused. It can be resumed once the mount is recovered, '
            'and it centers on the target before the next frame.',
      if (entry.autoRecovering)
        'Recovering on its own: taking a frame to plate solve, then syncing '
            'and resuming.',
    ];

    return Semantics(
      container: true,
      liveRegion: true,
      label: title,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceLg,
          vertical: SkotiqTokens.spaceMd,
        ),
        decoration: BoxDecoration(
          color: colors.error.withValues(alpha: 0.18),
          border: Border(
            top: BorderSide(color: colors.error, width: 2),
            bottom: BorderSide(color: colors.error.withValues(alpha: 0.7)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                LucideIcons.alertOctagon,
                size: 22,
                color: colors.error,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize14,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  for (final line in lines)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        line,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                if (fault != null && lost == null)
                  SkotiqButton(
                    label: 'Mount checked',
                    icon: LucideIcons.check,
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    isLoading: _busy,
                    semanticsHint:
                        'Say the mount has stopped and its position is right',
                    onPressed: stillMoving || _busy ? null : _acknowledge,
                  ),
                SkotiqButton(
                  label: 'Recover position',
                  icon: LucideIcons.crosshair,
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                  onPressed: stillMoving
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) =>
                              MountGuardRecoveryDialog(deviceId: entry.deviceId),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Abort slew, MoveAxis 0 on RA, ... (round 2: ...)" from the native list.
String _summarizeAttempts(List<String> attempts) {
  final rounds = <String, List<String>>{};
  for (final a in attempts) {
    final colon = a.indexOf(': ');
    final round = colon > 0 ? a.substring(0, colon) : '';
    final what = colon > 0 ? a.substring(colon + 2) : a;
    rounds.putIfAbsent(round, () => []).add(what);
  }
  if (rounds.length == 1) return rounds.values.first.join(', ');
  return '${rounds.values.first.join(', ')} (${rounds.length} rounds)';
}

/// The operator-facing text of a guard refusal.
String mountGuardErrorText(Object error) {
  final bridge = bridgeErrorMessage(error);
  if (bridge != null) return bridge;
  if (error is ServerError) return error.message;
  return error.toString().replaceFirst(RegExp(r'^[A-Za-z]*(Exception|Error): '), '');
}
