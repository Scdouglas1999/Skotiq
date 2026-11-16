import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../../widgets/hips/hips_attribution_badge.dart';

/// The credit the survey's publisher asks for, shown while its imagery is on
/// the framing canvas, by either delivery path: the single hips2fits cutout
/// or the streamed HiPS tiles.
///
/// The publisher's own `properties` wording is fetched only for surveys with a
/// verified HiPS pyramid while the tile layer is on; every other survey uses
/// the registry's static credit, which needs no network.
class FramingSurveyCredit extends ConsumerWidget {
  const FramingSurveyCredit({super.key, this.padding = EdgeInsets.zero});

  /// Space around the credit, taken only when there is a credit to show.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surveySource =
        ref.watch(framingProvider.select((s) => s.surveySource));
    final tilesActive = ref.watch(hipsFramingActiveProvider(surveySource));
    final hasCutoutImagery =
        ref.watch(framingProvider.select((s) => s.surveyImage != null));
    final hasTileImagery = tilesActive &&
        ref.watch(
          hipsResidentTilesProvider
              .select((snapshot) => snapshot.hasAnyImagery),
        );
    final hasImagery = hasTileImagery || hasCutoutImagery;

    if (!tilesActive && !hasImagery) return const SizedBox.shrink();

    final propertiesAsync = tilesActive
        ? ref.watch(framingHipsPropertiesProvider(surveySource))
        : const AsyncValue<HipsProperties?>.data(null);
    final entry = HipsSurveyRegistry.entryFor(surveySource);
    return HipsAttributionBadge(
      properties: propertiesAsync.valueOrNull,
      visible: hasImagery,
      fallbackCredit: entry.attributionCredit,
      fallbackCreditUrl: entry.attributionUrl,
      padding: padding,
    );
  }
}
