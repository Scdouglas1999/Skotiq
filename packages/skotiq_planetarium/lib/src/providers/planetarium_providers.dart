import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../celestial_object.dart';
import '../coordinate_system.dart';
import '../catalogs/star_catalog.dart';
import '../catalogs/constellation_data.dart';
import '../catalogs/catalog.dart';
import '../catalogs/spatial_index.dart';
import '../catalogs/minor_planet_catalog.dart';
import '../astronomy/astronomy_calculations.dart';
import '../astronomy/planetary_positions.dart';
import '../astronomy/milky_way_data.dart';
import '../rendering/sky_renderer.dart';
import '../rendering/render_quality.dart';
import '../services/survey_image_service.dart';
import '../services/mosaic_planner.dart';
import '../planning/tonight_ranking.dart';
import '../util/aligned_ticker.dart';
import 'catalog_providers.dart';
import 'element_refresh_providers.dart';

part 'planetarium_providers/observer_time.dart';
part 'planetarium_providers/sky_view.dart';
part 'planetarium_providers/render_config.dart';
part 'planetarium_providers/catalog_astronomy.dart';
part 'planetarium_providers/equipment_view.dart';
part 'planetarium_providers/mosaic_targets.dart';
part 'planetarium_providers/object_search.dart';

/// Get display name for search matching
(String, String) _getDsoDisplayInfoForSearch(DeepSkyObject dso) {
  // If it's a Messier object, use Messier number as name
  if (dso.isMessier) {
    final messierNum = dso.messierNumber;
    if (messierNum != null) {
      return (messierNum, 'M');
    }
  }

  // For non-Messier objects, use NGC/IC designation as name
  final ngcIc = dso.ngcIcDesignation;
  if (ngcIc != null) {
    if (ngcIc.startsWith('NGC')) {
      return (ngcIc, 'NGC');
    } else if (ngcIc.startsWith('IC')) {
      return (ngcIc, 'IC');
    }
  }

  // Fallback to id and extract catalog prefix
  if (dso.id.startsWith('NGC')) {
    return (dso.id, 'NGC');
  } else if (dso.id.startsWith('IC')) {
    return (dso.id, 'IC');
  } else if (dso.id.startsWith('M')) {
    return (dso.id, 'M');
  }

  // Last resort: use name and id
  return (dso.name, dso.id);
}
