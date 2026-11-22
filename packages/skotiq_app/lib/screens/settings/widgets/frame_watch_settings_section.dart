import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart' show ObstructionAction;
import 'package:skotiq_core/providers.dart';

import '../../../utils/snackbar_helper.dart';
import 'settings_widgets.dart';

/// The run's frame watch: how far a frame's solved center may drift from the
/// target before the run recenters, whether frames are checked for an
/// obstruction, and what a confirmed obstruction does. All are read when a
/// run starts.
class FrameWatchSettingsSection extends ConsumerStatefulWidget {
  const FrameWatchSettingsSection({
    super.key,
    this.showObstructionDetection = true,
  });

  final bool showObstructionDetection;

  @override
  ConsumerState<FrameWatchSettingsSection> createState() =>
      _FrameWatchSettingsSectionState();
}

class _FrameWatchSettingsSectionState
    extends ConsumerState<FrameWatchSettingsSection> {
  Future<void> _save(Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      if (mounted)
        context.showErrorSnackBar('Could not save: ${userFacingError(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(frameWatchSettingsProvider).valueOrNull ??
        FrameWatchSettings.initial;
    final notifier = ref.read(frameWatchSettingsProvider.notifier);
    return SettingsSection(
      title: widget.showObstructionDetection
          ? 'Frame watch'
          : 'Recenter after drift',
      children: [
        SettingRow(
          title: 'Recenter after drift trigger',
          subtitle:
              'Plate solve every saved light frame and recenter between exposures '
              'when the target drifts too far. Applies to the next run; '
              'saved for all sequences.',
          trailing: SettingsSwitch(
            key: const ValueKey('frame-watch-recenter-enabled'),
            value: settings.recenterEnabled,
            onChanged: (value) =>
                _save(() => notifier.setRecenterEnabled(value)),
          ),
        ),
        SettingRow(
          title: 'Maximum drift',
          subtitle:
              'Default: 30 arcseconds. Measured from the first successfully solved '
              'light frame after initial centering, separately for each target. '
              'The reference stays fixed for the run. Frames beyond the limit '
              'are marked Off target while automatic recentering is enabled.',
          trailing: SettingsNumberInput(
            key: const ValueKey('frame-watch-drift-limit'),
            authoritativeValue: settings.driftLimitArcsec,
            authorityKey: ref.watch(backendProvider),
            suffix: 'arcsec',
            min: frameWatchDriftLimitMinArcsec,
            max: frameWatchDriftLimitMaxArcsec,
            decimals: 0,
            onChanged: (value) =>
                _save(() => notifier.setDriftLimitArcsec(value)),
          ),
        ),
        if (widget.showObstructionDetection) ...[
          SettingRow(
            title: 'Detect obstructions',
            subtitle:
                'Off by default. Watch for trees or a roof entering the field: '
                'stars fade while the sky background stays the same, and a '
                'frame higher in the sky still has stars. Clouds can look the '
                'same, so a confirmed obstruction only notifies unless you '
                'choose Move on below.',
            trailing: SettingsSwitch(
              key: const ValueKey('frame-watch-obstruction-detection'),
              value: settings.obstructionDetection,
              onChanged: (value) =>
                  _save(() => notifier.setObstructionDetection(value)),
            ),
          ),
          if (settings.obstructionDetection)
            SettingRow(
              title: 'When an obstruction is confirmed',
              subtitle:
                  'Notify: tell you and keep imaging the target. Move on: '
                  'mark its frames Obstructed, save the spot to this site\'s '
                  'horizon and go to the next target that is up and clear; '
                  'with none left, the night ends and the plan\'s end steps '
                  'run.',
              trailing: settingsTrailingChoice<ObstructionAction>(
                value: settings.obstructionAction,
                values: ObstructionAction.values,
                labelOf: (action) => switch (action) {
                  ObstructionAction.notify => 'Notify',
                  ObstructionAction.moveOn => 'Move on',
                },
                onChanged: (action) =>
                    _save(() => notifier.setObstructionAction(action)),
              ),
            ),
        ],
      ],
    );
  }
}
