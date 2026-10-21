/// Skotiq Planetarium - Flutter GPU sky renderer
library;

// Core models
export 'src/celestial_object.dart';
export 'src/coordinate_system.dart';

// Catalogs
export 'src/catalogs/catalog.dart';
export 'src/catalogs/hyg_depth.dart';
export 'src/catalogs/star_catalog.dart';
export 'src/catalogs/constellation_data.dart';
export 'src/catalogs/constellation_names.dart';
export 'src/catalogs/constellation_art.dart';
export 'src/catalogs/catalog_manager.dart';
export 'src/catalogs/target_designation.dart';
export 'src/catalogs/target_name_resolver.dart';
export 'src/catalogs/catalog_region_scan.dart';
export 'src/catalogs/hyperleda_catalog.dart';
export 'src/catalogs/glade_plus_catalog.dart';
export 'src/catalogs/annotation_catalog.dart';
export 'src/catalogs/satellite_catalog.dart';
export 'src/catalogs/variable_star_catalog.dart';
export 'src/catalogs/minor_planet_catalog.dart';
export 'src/catalogs/deep_star_tile.dart';
export 'src/catalogs/deep_star_store.dart';
export 'src/catalogs/deep_star_catalog.dart';
export 'src/catalogs/mpcorb.dart';

// Astronomy calculations
export 'src/astronomy/astronomy_calculations.dart';
export 'src/astronomy/observability.dart';
export 'src/astronomy/planetary_positions.dart';
export 'src/astronomy/milky_way_data.dart';
export 'src/astronomy/sgp4.dart';

// Rendering
export 'src/rendering/sky_renderer.dart';
export 'src/rendering/render_quality.dart';
export 'src/rendering/fov_overlays.dart';

// Catalogs (additional)
export 'src/catalogs/spatial_index.dart';

// Services
export 'src/services/survey_image_service.dart';
export 'src/services/mosaic_geometry.dart';
export 'src/services/mosaic_planner.dart';
export 'src/services/geolocation_service.dart';
export 'src/services/element_refresh_service.dart';

// Planning
export 'src/planning/target_scoring.dart';
export 'src/planning/tonight_ranking.dart';
export 'src/planning/weighted_score.dart';

// Providers
export 'src/providers/planetarium_providers.dart';
export 'src/providers/catalog_providers.dart';
export 'src/providers/target_queue_provider.dart';
export 'src/providers/platform_providers.dart';
export 'src/providers/performance_providers.dart';
export 'src/providers/satellite_providers.dart';
export 'src/providers/variable_star_providers.dart';
export 'src/providers/minor_planet_providers.dart';
export 'src/providers/deep_star_providers.dart';
export 'src/providers/element_refresh_providers.dart';

// Widgets
export 'src/widgets/interactive_sky_view.dart';
export 'src/widgets/framing_view.dart';
export 'src/widgets/time_control_panel.dart';
export 'src/widgets/simulated_time_scope.dart';
export 'src/widgets/object_details_panel.dart';
export 'src/widgets/compass_hud.dart';
export 'src/widgets/fov_rings_overlay.dart';
export 'src/widgets/fov_presets.dart';
export 'src/widgets/multi_fov_overlay.dart';
export 'src/widgets/sky_minimap.dart';
export 'src/widgets/adaptive_layout.dart';
