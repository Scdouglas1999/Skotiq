import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The hardware-presets provider deliberately sits outside the core barrel (it
// would collide with `cameraPresetsProvider`), so it is imported by source
// path — the precedent set by hardware_preset_picker_dialog.dart.
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'device_picker_step.dart';

/// Camera selection step. Picks a camera via the unified discovery
/// pipeline. The driver-reported display name is captured so the profile
/// row has a friendly label even before connection.
class OnboardingCameraStep extends ConsumerWidget {
  const OnboardingCameraStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(onboardingDraftProvider);
    final notifier = ref.read(onboardingDraftProvider.notifier);

    return OnboardingDevicePickerBody(
      title: 'Pick your camera',
      subtitle:
          'Cameras discovered through the drivers you selected appear here. The brand is reported by the driver itself.',
      icon: SkotiqIcons.camera,
      deviceType: DeviceType.camera,
      selectedDeviceId: draft.cameraId,
      selectedDeviceName: draft.cameraName,
      onSelected: (device) {
        // Seed the optical train's pixel size from the built-in camera
        // library. Pixel pitch is a physical property of the sensor the
        // driver just named, not a preference — asking the user to "look
        // this up in your camera spec sheet" two steps later was asking for
        // a number the app already held. Only on an actual camera change, so
        // a value the user typed by hand survives re-selecting the same
        // camera; an unrecognised camera matches nothing and prefills
        // nothing rather than guessing.
        final changedCamera =
            ref.read(onboardingDraftProvider).cameraId != device.activeDeviceId;
        final preset = changedCamera
            ? ref
                .read(hardwarePresetsServiceProvider)
                .matchCameraByName(device.displayName)
            : null;
        notifier.setCamera(
          id: device.activeDeviceId,
          name: device.displayName,
          pixelSizeMicrons: preset?.pixelSizeMicrons,
        );
      },
      onCleared: () => notifier.setCamera(id: '', name: ''),
    );
  }
}
