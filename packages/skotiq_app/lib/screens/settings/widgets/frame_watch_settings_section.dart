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
  const FrameWatchSettingsSection({super.key, this.isMobile = false});

  final bool isMobile;

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
      title: 'Frame watch',
      isMobile: widget.isMobile,
      children: [
        SettingRow(
          icon: LucideIcons.crosshair,
          title: 'Recenter after drift',
          subtitle:
              'When a solved frame is farther from the target than this share '
              'of the shorter side of the field, the run recenters. Frames '
              'taken off target are marked Off target and do not count as '
              'integration.',
          trailing: SettingsNumberInput(
            key: const ValueKey('frame-watch-drift-limit'),
            controller: _driftController,
            authoritativeValue: settings.driftLimitPercent,
            authorityKey: ref.watch(backendProvider),
            suffix: '%',
            min: frameWatchDriftLimitMinPercent,
            max: frameWatchDriftLimitMaxPercent,
            decimals: 0,
            onChanged: (value) =>
                _save(() => notifier.setDriftLimitPercent(value)),
            isMobile: widget.isMobile,
          ),
        ),
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
