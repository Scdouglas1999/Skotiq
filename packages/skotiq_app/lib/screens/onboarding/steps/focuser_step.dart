import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'device_picker_step.dart';

/// Focuser selection. Optional — manual focusers don't show up via
/// driver discovery so the user can skip this step entirely.
class OnboardingFocuserStep extends ConsumerWidget {
  const OnboardingFocuserStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(onboardingDraftProvider);
    final notifier = ref.read(onboardingDraftProvider.notifier);

    return OnboardingDevicePickerBody(
      title: 'Pick your focuser (optional)',
      subtitle:
          'An electronic focuser unlocks autofocus runs. If you focus manually, skip this step.',
      icon: SkotiqIcons.focuser,
      deviceType: DeviceType.focuser,
      selectedDeviceId: draft.focuserId,
      selectedDeviceName: draft.focuserName,
      allowSkip: true,
      onSelected: (device) => notifier.setFocuser(
        id: device.activeDeviceId,
        name: device.displayName,
      ),
      onCleared: () => notifier.setFocuser(id: ''),
    );
  }
}
