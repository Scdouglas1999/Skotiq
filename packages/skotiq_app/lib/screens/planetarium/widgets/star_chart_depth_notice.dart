import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../settings/catalog_settings_screen.dart';

/// States that the chart has zoomed past the bundled catalog's depth.
///
/// At an imaging-scale field the sky goes almost empty, which reads as "this
/// patch of sky is bare" rather than "this catalog stops at magnitude 9".
/// Framing and guide-star checks are exactly what a 1 deg field is for, so a
/// chart that is ~30x shallower than the real sky has to say so instead of
/// passing for one.
///
/// [StarCatalogFallbackBanner] covers the louder case (no HYG at all) and takes
/// precedence; this only speaks when a real catalog is installed and the zoom
/// has simply outrun it.
class StarChartDepthNotice extends ConsumerWidget {
  const StarChartDepthNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(starCatalogFallbackProvider)) return const SizedBox.shrink();
    if (!ref.watch(starChartDepthLimitedProvider)) {
      return const SizedBox.shrink();
    }

    final installed = ref.watch(deepStarManifestProvider).valueOrNull != null;
    final floor = kHygFaintFloorMag.toStringAsFixed(1);

    return SkotiqAlert(
      severity: SkotiqAlertSeverity.info,
      compact: true,
      title: 'Chart is shallower than the sky',
      message: installed
          ? 'The bundled catalog is complete to about magnitude $floor, so this '
              'field shows a fraction of the real star count. Turn on the '
              'deep-star tier to draw the rest.'
          : 'The bundled catalog is complete to about magnitude $floor, so this '
              'field shows a fraction of the real star count. No deep-star '
              'tileset is published; it must be self-hosted.',
      action: installed
          ? SkotiqButton(
              label: 'Enable',
              variant: ButtonVariant.outline,
              size: ButtonSize.small,
              onPressed: () =>
                  ref.read(showDeepStarsProvider.notifier).state = true,
            )
          // "Install" promised a download that does not exist: this only opens
          // the Catalog Settings form asking the user to build a tileset with
          // tools/catalog_prep and host it themselves — the same form the
          // Layers panel's "Configure source..." row opens. Kept to one word
          // because the alert lays the action out beside the message, and a
          // wider button squeezes that column into a very tall block at phone
          // widths.
          : SkotiqButton(
              label: 'Configure',
              variant: ButtonVariant.outline,
              size: ButtonSize.small,
              onPressed: () => _openCatalogSettings(context, ref),
            ),
    );
  }

  void _openCatalogSettings(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 800,
            designMaxHeight: 700,
          ),
          child: const CatalogSettingsScreen(),
        ),
      ),
    ).then((_) {
      ref.read(deepStarManifestRefreshProvider.notifier).state++;
    });
  }
}
