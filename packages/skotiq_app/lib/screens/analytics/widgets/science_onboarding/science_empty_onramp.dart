import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What Science is for, under the guide on an empty page. It offers the guide
/// only when the guide is collapsed; open, the guide above is the one action.
class ScienceEmptyOnramp extends ConsumerWidget {
  final VoidCallback onShowSteps;

  const ScienceEmptyOnramp({super.key, required this.onShowSteps});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guideCollapsed = ref.watch(
      scienceSettingsProvider.select(
        (s) => s.valueOrNull?.scienceGuideCollapsed ?? false,
      ),
    );
    return EmptyState(
      icon: LucideIcons.flaskConical,
      title: 'Turn pretty pictures into real measurements',
      body: 'Five short steps take you from a calibrated sky to data the AAVSO '
          'and MPC can use. Start whenever you are at the eyepiece.',
      action: !guideCollapsed
          ? null
          : SkotiqButton(
              label: 'Show me the 5 steps',
              icon: LucideIcons.listChecks,
              onPressed: () {
                ref
                    .read(scienceSettingsProvider.notifier)
                    .setScienceGuideCollapsed(false);
                onShowSteps();
              },
            ),
    );
  }
}
