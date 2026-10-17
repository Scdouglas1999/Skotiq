import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../settings/catalog_settings_screen.dart';

/// Warns that the sky on screen is the built-in fallback star list, not a real
/// catalog.
///
/// The fallback is a few dozen naked-eye stars, so the view silently loses
/// almost everything a user would plan or point at. It engages whenever the HYG
/// file is absent — including after an upgrade renames it — so the state has to
/// announce itself rather than pass for a working sky.
class StarCatalogFallbackBanner extends ConsumerWidget {
  const StarCatalogFallbackBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(starCatalogFallbackProvider)) {
      return const SizedBox.shrink();
    }
    final count = ref.watch(fallbackStarCountProvider);

    return SkotiqAlert(
      severity: SkotiqAlertSeverity.warning,
      compact: true,
      title: 'Star catalog not installed',
      message: 'Showing the $count-star built-in list. Most stars, and every '
          'catalog search that depends on them, are missing until you install '
          'the HYG catalog.',
      action: SkotiqButton(
        label: 'Install',
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
      ref.invalidate(starCatalogProvider);
      ref.invalidate(starsProvider);
    });
  }
}
