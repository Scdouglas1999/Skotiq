import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Where calibration lives: the Darkroom's Calibration tab holds the
/// library of darks, bias and flats and the settings for calibrating frames
/// while imaging.
const String calibrationTabLocation = '/darkroom?tab=calibration';

/// Settings section keys that used to hold calibration pages. Each now
/// redirects to [calibrationTabLocation].
const Set<String> calibrationSettingsSectionKeys = {
  'calibration',
  'dark-library',
  'calibration-library',
};

/// Where a `/settings` link should go instead: the Calibration tab for any
/// of the old calibration sections, null for every other section.
String? calibrationSettingsRedirect(Uri uri) =>
    calibrationSettingsSectionKeys.contains(uri.queryParameters['section'])
    ? calibrationTabLocation
    : null;

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
      GoRouter.maybeOf(context)?.go(calibrationTabLocation);
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
              onPressed: () => context.go(calibrationTabLocation),
            ),
          ],
        ),
      ),
    );
  }
}
