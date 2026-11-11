import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';

/// The Settings Calibration entry: opening it goes to the Darkroom's
/// Calibration tab. The pointer stays visible in case navigation is not
/// available, so the entry is never a dead end.
class CalibrationSettingsRedirect extends StatefulWidget {
  const CalibrationSettingsRedirect({super.key, this.isMobile = false});

  final bool isMobile;

  @override
  State<CalibrationSettingsRedirect> createState() =>
      _CalibrationSettingsRedirectState();
}

class _CalibrationSettingsRedirectState
    extends State<CalibrationSettingsRedirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      GoRouter.maybeOf(context)
          ?.go(darkroomTabLocation(DarkroomTab.calibration));
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Center(
      child: Padding(
        padding: SkotiqTokens.padding2xl,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Calibration is in the Darkroom',
              style: SkotiqTypography.sectionTitle.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              'The library of darks, bias and flats, the frames waiting to be '
              'built, and the settings for calibrating frames while imaging.',
              textAlign: TextAlign.center,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            SkotiqButton(
              label: 'Open Calibration',
              icon: LucideIcons.arrowRight,
              onPressed: () =>
                  context.go(darkroomTabLocation(DarkroomTab.calibration)),
            ),
          ],
        ),
      ),
    );
  }
}
