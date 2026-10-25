import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The Darkroom's calibration library: darks, bias and flats, and the raw
/// calibration frames waiting to be built.
class DarkroomCalibrationTab extends StatelessWidget {
  const DarkroomCalibrationTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: EmptyState(
        icon: SkotiqIcons.sliders,
        title: 'Calibration library',
        body: 'Darks, bias and flats are listed in Settings for now.',
        action: SkotiqButton(
          label: 'Open the calibration library',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => context.go('/settings?section=calibration-library'),
        ),
      ),
    );
  }
}
