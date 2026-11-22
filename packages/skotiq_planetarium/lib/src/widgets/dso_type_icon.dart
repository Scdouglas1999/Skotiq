import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

/// The icon a catalog object of [type] is shown with.
IconData dsoTypeIcon(DsoType type) => switch (type) {
  DsoType.galaxy ||
  DsoType.galaxyPair ||
  DsoType.galaxyTriplet ||
  DsoType.galaxyGroup => LucideIcons.orbit,
  DsoType.nebula ||
  DsoType.emissionNebula ||
  DsoType.reflectionNebula ||
  DsoType.darkNebula ||
  DsoType.hiiRegion => LucideIcons.cloud,
  DsoType.openCluster ||
  DsoType.clusterWithNebulosity ||
  DsoType.clusterWithEmissionNebula ||
  DsoType.clusterWithReflectionNebula => LucideIcons.asterisk,
  DsoType.globularCluster => LucideIcons.circle,
  DsoType.planetaryNebula => LucideIcons.circleSlash,
  DsoType.supernova => LucideIcons.zap,
  DsoType.starCloud => LucideIcons.sparkles,
  DsoType.asterism => LucideIcons.shapes,
  DsoType.star ||
  DsoType.doubleStar ||
  DsoType.association ||
  DsoType.nova ||
  DsoType.other => LucideIcons.star,
};
