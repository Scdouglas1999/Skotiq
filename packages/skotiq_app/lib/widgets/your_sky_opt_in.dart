import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What Your Sky does and what it costs, for every place that offers to turn
/// it on. The disk figures are measured: a real one-field night (NGC 891, 149
/// tiles across four filters) takes 1.4 GB with compressed tiles, and the
/// rig's nights of 11.8 to 12.7 GB uncompressed come to 2.7 to 2.9 GB.
String yourSkyCostText({int limitGb = defaultSkyAtlasLimitGb}) {
  final limit = limitGb > 0
      ? 'It stops growing at $limitGb ${ByteFormat.gigaUnit}, which you can change in Settings > '
          'Science.'
      : 'You have set no size limit.';
  return 'Your sky stacks every accepted, plate-solved light frame into a '
      'map of all the sky you have imaged, which First Light and shared '
      'imaging build on. It uses about 1.5 ${ByteFormat.gigaUnit} of disk for each target '
      'you image in a night, 2 to 3 ${ByteFormat.gigaUnit} on a typical night. '
      '$limit';
}

/// Ask before turning Your Sky on, and turn it on if the user agrees.
/// Returns whether it is now on.
Future<bool> confirmTurnOnYourSky(BuildContext context, WidgetRef ref) async {
  final limitGb =
      ref.read(scienceSettingsProvider).valueOrNull?.skyAtlasLimitGb ??
          defaultSkyAtlasLimitGb;
  final agreed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Turn on Your sky?'),
      content: SizedBox(
        width: 440,
        child: Text(yourSkyCostText(limitGb: limitGb)),
      ),
      actions: [
        SkotiqButton(
          label: 'Not now',
          variant: ButtonVariant.secondary,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        SkotiqButton(
          label: 'Turn on',
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  if (agreed != true) return false;
  await ref
      .read(scienceSettingsProvider.notifier)
      .setFeatureEnabled(ScienceFeature.skyAtlas, true);
  return true;
}

/// Full-area state for a surface that shows the atlas while Your Sky is off.
/// [purpose] finishes "Turn on Your sky to ...".
class YourSkyOffPanel extends ConsumerWidget {
  final String purpose;

  const YourSkyOffPanel({super.key, required this.purpose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: EmptyState(
            icon: SkotiqIcons.layers,
            title: 'Your sky is off',
            body: 'Turn on Your sky to $purpose.\n\n${yourSkyCostText()}',
            action: SkotiqButton(
              label: 'Turn on Your sky',
              onPressed: () => confirmTurnOnYourSky(context, ref),
            ),
          ),
        ),
      ),
    );
  }
}

/// One-line note above a list or form that depends on Your Sky while it is
/// off. [purpose] finishes "Turn on Your sky to ...".
class YourSkyOffBanner extends ConsumerWidget {
  final String purpose;

  const YourSkyOffBanner({super.key, required this.purpose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(SkotiqIcons.layers, size: 16, color: colors.textSecondary),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              'Your sky is off. Turn it on to $purpose.',
              style: SkotiqTypography.labelQuiet.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: 'Turn on',
            variant: ButtonVariant.secondary,
            onPressed: () => confirmTurnOnYourSky(context, ref),
          ),
        ],
      ),
    );
  }
}
