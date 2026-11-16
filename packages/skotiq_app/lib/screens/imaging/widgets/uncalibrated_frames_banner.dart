import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../router/darkroom_route.dart';
import '../../../utils/darkroom_navigation.dart' show darkroomTabLocation;

/// Says, for as long as it lasts, that auto-calibration is keeping captured
/// lights uncalibrated and why, with the way to the settings that fix it.
///
/// A banner rather than a toast: the cause holds for every frame until the
/// operator changes something, and a toast is gone before a loop's next frame.
/// It takes no height when calibration works or the operator closed it.
class UncalibratedFramesBanner extends ConsumerWidget {
  const UncalibratedFramesBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = ref.watch(autoCalibrationNoticeProvider);
    if (notice == null || notice.dismissed) return const SizedBox.shrink();
    final frames = notice.frames == 1 ? 'One frame' : '${notice.frames} frames';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceMd,
        0,
      ),
      child: SkotiqBanner(
        title: 'Frames are being saved uncalibrated.',
        message: '${notice.sentence} $frames kept as captured so far.',
        tone: BannerTone.warning,
        action: SkotiqButton(
          label: 'Calibration settings',
          size: ButtonSize.small,
          variant: ButtonVariant.secondary,
          onPressed: () =>
              context.go(darkroomTabLocation(DarkroomTab.calibration)),
        ),
        onDismiss: () =>
            ref.read(autoCalibrationNoticeProvider.notifier).dismiss(),
      ),
    );
  }
}
