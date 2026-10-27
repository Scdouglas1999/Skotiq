import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../utils/snackbar_helper.dart';
import 'settings_widgets.dart';

/// The run's frame watch: how far a frame's solved center may drift from the
/// target before the run recenters, and whether frames are checked for an
/// obstruction. Both are read when a run starts.
class FrameWatchSettingsSection extends ConsumerStatefulWidget {
  const FrameWatchSettingsSection({
    super.key,
    this.isMobile = false,
    this.showObstructionDetection = true,
  });

  final bool isMobile;
  final bool showObstructionDetection;

  @override
  ConsumerState<FrameWatchSettingsSection> createState() =>
      _FrameWatchSettingsSectionState();
}

class _FrameWatchSettingsSectionState
    extends ConsumerState<FrameWatchSettingsSection> {
  final TextEditingController _driftController = TextEditingController();

  @override
  void dispose() {
    _driftController.dispose();
    super.dispose();
  }

  Future<void> _save(Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      if (mounted) context.showErrorSnackBar('Could not save: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(frameWatchSettingsProvider).valueOrNull ??
        const FrameWatchSettings();
    final notifier = ref.read(frameWatchSettingsProvider.notifier);
    return SettingsSection(
      title: widget.showObstructionDetection
          ? 'Frame watch'
          : 'Recenter after drift',
      isMobile: widget.isMobile,
      children: [
        SettingRow(
          icon: LucideIcons.crosshair,
          title: 'Automatic recentering',
          subtitle:
              'Plate solve saved light frames and recenter between exposures '
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
          icon: LucideIcons.move,
          title: 'Maximum drift',
          subtitle:
              'Default: 60 arcseconds (1 arcminute). Measured from the planned '
              'target center, not the previous frame. Frames beyond the limit '
              'are marked Off target while automatic recentering is enabled.',
          trailing: SettingsNumberInput(
            key: const ValueKey('frame-watch-drift-limit'),
            controller: _driftController,
            authoritativeValue: settings.driftLimitArcsec,
            authorityKey: ref.watch(backendProvider),
            suffix: 'arcsec',
            min: frameWatchDriftLimitMinArcsec,
            max: frameWatchDriftLimitMaxArcsec,
            decimals: 0,
            onChanged: (value) =>
                _save(() => notifier.setDriftLimitArcsec(value)),
            isMobile: widget.isMobile,
          ),
          isLast: !widget.showObstructionDetection,
        ),
        if (widget.showObstructionDetection)
          SettingRow(
            icon: LucideIcons.mountain,
            title: 'Detect obstructions',
            subtitle:
                'Watch for trees or a roof entering the field: stars fade while '
                'the sky background stays the same. A confirmed obstruction is '
                'learned for this site, its frames are marked Obstructed, and '
                'the run moves to the next target. Clouds are not obstructions.',
            trailing: SettingsSwitch(
              key: const ValueKey('frame-watch-obstruction-detection'),
              value: settings.obstructionDetection,
              onChanged: (value) =>
                  _save(() => notifier.setObstructionDetection(value)),
            ),
            isLast: true,
          ),
      ],
    );
  }
}
