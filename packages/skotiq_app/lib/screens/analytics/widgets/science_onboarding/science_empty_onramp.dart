import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class ScienceEmptyOnramp extends ConsumerWidget {
  final VoidCallback onShowSteps;

  const ScienceEmptyOnramp({super.key, required this.onShowSteps});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return EmptyState(
      icon: LucideIcons.flaskConical,
      title: 'Turn pretty pictures into real measurements',
      body: 'Five short steps take you from a calibrated sky to data the AAVSO '
          'and MPC can use. Start whenever you are at the eyepiece.',
      action: SkotiqButton(
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
