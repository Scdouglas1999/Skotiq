import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart' show darkroomActivityRoute;
import 'package:skotiq_ui/skotiq_ui.dart';

/// The Settings entry for what happens at the end of a night. The switches
/// live in the Darkroom's Activity tab, beside the history they produce;
/// opening this entry goes there. The pointer stays on screen in case
/// navigation is not available, so the entry is never a dead end.
class DarkroomAutopilotSettings extends StatefulWidget {
  const DarkroomAutopilotSettings({super.key, this.isMobile = false});

  final bool isMobile;

  @override
  State<DarkroomAutopilotSettings> createState() =>
      _DarkroomAutopilotSettingsState();
}

class _DarkroomAutopilotSettingsState extends State<DarkroomAutopilotSettings> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      GoRouter.maybeOf(context)?.go(darkroomActivityRoute);
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
              'Night-end automation is in the Darkroom',
              textAlign: TextAlign.center,
              style: SkotiqTypography.sectionTitle.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              'Taking darks and bias, building masters from every night of '
              'each target, delivery and the morning message each have a '
              'switch in the Activity tab, next to the history of past '
              'nights.',
              textAlign: TextAlign.center,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            SkotiqButton(
              key: const ValueKey('darkroom-automation-open'),
              label: 'Open Activity',
              icon: SkotiqIcons.arrowRight,
              onPressed: () => context.go(darkroomActivityRoute),
            ),
          ],
        ),
      ),
    );
  }
}
