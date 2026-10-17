import 'dart:io' show IOException;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../red_night_filter.dart';
import 'location_marker.dart';
import 'motion_indicator.dart';

/// Weather radar map widget with base map and radar overlay.
///
/// Displays an interactive map with OpenStreetMap base tiles, radar overlay,
/// user location marker, alert radius circle, and optional cloud motion indicator.
/// Supports both compact (dashboard) and full-screen modes.
class WeatherRadarMap extends ConsumerStatefulWidget {
  /// Current radar frame to display
  final RadarFrame? currentFrame;

  /// User's latitude
  final double latitude;

  /// User's longitude
  final double longitude;

  /// Compact mode for dashboard widget
  final bool compact;

  /// Alert radius circle (km)
  final double alertRadiusKm;

  /// Radar tile opacity (0.0 - 1.0)
  final double radarOpacity;

  /// Contrast enhancement level (0.0 = none, 1.0 = moderate, 2.0 = high)
  /// Applied to radar/satellite tiles to improve visibility of cloud boundaries.
  final double contrastLevel;

  /// Cloud motion direction (degrees, 0=N, for indicator arrow)
  final double? motionDirection;

  /// Human-readable name of the data source (e.g. "GOES Satellite"), shown in
  /// the info overlay for attribution. Null hides the source label.
  final String? sourceName;

  /// When the displayed data was fetched, shown as a freshness indicator in
  /// the info overlay. Null hides the freshness label.
  final DateTime? fetchedAt;

  /// Callback when map tapped (for navigation in compact mode)
  final VoidCallback? onTap;

  const WeatherRadarMap({
    super.key,
    this.currentFrame,
    required this.latitude,
    required this.longitude,
    this.compact = false,
    this.alertRadiusKm = 30.0,
    this.radarOpacity = 0.7,
    this.contrastLevel = 1.5,
    this.motionDirection,
    this.sourceName,
    this.fetchedAt,
    this.onTap,
  });

  @override
  ConsumerState<WeatherRadarMap> createState() => _WeatherRadarMapState();
}

class _WeatherRadarMapState extends ConsumerState<WeatherRadarMap> {
  late MapController _mapController;

  /// Tile fetcher that retries a dropped CONNECTION, not just a 503.
  ///
  /// flutter_map already defaults to a `RetryClient`, which reads like this is
  /// handled — but `package:http`'s default only retries a RESPONSE whose
  /// status is 503, and never an exception. The failures actually seen against
  /// mesonet's WMS are `ClientException: Connection closed while receiving
  /// data` under a burst of tile requests: no response, no status, nothing the
  /// default rule can match. Each one left a permanent hole in the imagery,
  /// because `EvictErrorTileStrategy.dispose` removes the tile and nothing
  /// ever asks again.
  ///
  /// One client for the whole map, built once: a client per rebuild would drop
  /// its connection pool on every frame.
  late final http.BaseClient _tileClient = RetryClient(
    http.Client(),
    retries: 3,
    when: (response) => response.statusCode >= 500,
    whenError: (error, _) =>
        error is http.ClientException || error is IOException,
    delay: (attempt) => Duration(milliseconds: 200 * (attempt + 1)),
  );

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  @override
  void dispose() {
    _mapController.dispose();
    _tileClient.close();
    super.dispose();
  }

  /// Formats how long ago [time] was, in compact human terms.
  String _formatAge(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Calculate initial zoom level to fit alert radius
  double _calculateInitialZoom() {
    // Approximate zoom level based on alert radius
    // Larger radius = zoom out more
    if (widget.alertRadiusKm <= 10) return 11.0;
    if (widget.alertRadiusKm <= 30) return 9.0;
    if (widget.alertRadiusKm <= 50) return 8.0;
    if (widget.alertRadiusKm <= 100) return 7.0;
    return 6.0;
  }

  /// Creates a color matrix applying contrast enhancement AND layer opacity.
  ///
  /// The contrast parameter controls the intensity:
  /// - 0.0 = no enhancement (identity matrix)
  /// - 1.0 = moderate enhancement (good for most conditions)
  /// - 2.0 = high enhancement (useful for subtle cloud features)
  ///
  /// This uses a standard contrast matrix formula that also slightly increases
  /// brightness in dark areas while compressing bright areas, making the
  /// distinction between clear sky and clouds more obvious.
  ///
  /// Opacity rides in the alpha row instead of a separate [Opacity] widget.
  /// Stacked ColorFiltered + Opacity cost two saveLayers PER TILE, which is
  /// the amplifier that turned a 40x40 marker pulse into a full-map raster
  /// load; one filter costs one. For a tile this is exact, not approximate:
  /// group opacity and per-pixel alpha only diverge when a layer overdraws
  /// itself, and a tile is a single image draw.
  ColorFilter _buildTileFilter(double contrast, double opacity) {
    // Base contrast multiplier (1.0 = no change, higher = more contrast)
    // Using a sigmoid-like curve for natural-looking enhancement
    final contrastMultiplier = 1.0 + (contrast * 0.5);

    // Offset to adjust midpoint (negative pulls dark colors darker,
    // positive pulls bright colors brighter)
    final offset = -0.5 * (contrastMultiplier - 1.0) * 255;

    // Slight gamma-style boost to make clouds "pop" more
    // by adding extra brightness to already-bright pixels
    final brightBoost = contrast * 0.08;

    return ColorFilter.matrix(<double>[
      // Red channel: enhanced contrast + slight warm shift for clouds
      contrastMultiplier + brightBoost, 0, 0, 0, offset,
      // Green channel: enhanced contrast
      0, contrastMultiplier + brightBoost, 0, 0, offset,
      // Blue channel: enhanced contrast + cooler for clear sky depth
      0, 0, contrastMultiplier + brightBoost * 0.5, 0, offset,
      // Alpha channel: layer opacity
      0, 0, 0, opacity, 0,
    ]);
  }

  /// Wraps a tile widget with contrast enhancement and opacity.
  Widget _buildEnhancedTile(
      Widget tileWidget, double opacity, double contrast) {
    if (contrast <= 0 && opacity >= 1.0) {
      return tileWidget;
    }
    return ColorFiltered(
      colorFilter: _buildTileFilter(contrast, opacity),
      child: tileWidget,
    );
  }

  /// Builds the appropriate tile layer based on the frame's tile type
  Widget _buildRadarTileLayer(
      RadarFrame frame, double opacity, double contrast) {
    // Create tile bounds from frame coverage to prevent NaN errors
    // when requesting tiles outside the provider's coverage area
    final tileBounds = LatLngBounds(
      LatLng(frame.south, frame.west),
      LatLng(frame.north, frame.east),
    );

    if (frame.tileType == RadarTileType.wms) {
      // WMS tile layer for NOAA/GOES satellite and similar services.
      //
      // NOT retinaMode. It reads like the lever that would ask the server for
      // more pixels, and for a WMS layer it is the opposite: flutter_map
      // resolves it to RetinaMode.simulation (tile_layer.dart:340 — server
      // mode requires a urlTemplate carrying `{r}`, which WMS has no room
      // for), which drops maxNativeZoom by one and scales each tile up 2x.
      // Measured live: the request stayed width=256&height=256 while every
      // tile came back one zoom coarser and painted at double size, so the
      // imagery got blockier. The server DOES hold more detail — an identical
      // bbox rendered at 1024px differs from the 256px render in 7% of
      // pixels — but reaching it needs a bigger width/height on the request
      // itself, not this flag.
      return TileLayer(
        wmsOptions: WMSTileLayerOptions(
          baseUrl: frame.tileUrlTemplate,
          layers: frame.wmsLayers != null ? [frame.wmsLayers!] : [],
          format: 'image/png',
          transparent: true,
          version: '1.1.1',
          crs: const Epsg3857(), // Web Mercator
          otherParameters: frame.wmsAdditionalOptions ?? {},
        ),
        // Stop asking the server for detail the instrument never had. GOES
        // CONUS IR is 4 km per pixel, which in Web Mercator at this latitude
        // is native around zoom 5 (4149 m/px) and already 2x upsampled at
        // zoom 6. This map opens at zoom 9 (259 m/px) for a 30 km alert
        // radius — SIXTEEN times finer than the data exists — and the server
        // answers by nearest-neighbour upsampling, which is where the hard
        // rectangular blocks come from. Capped here, flutter_map requests the
        // coarsest honest tile and scales it smoothly instead: the imagery
        // gets soft, which is what 4 km data honestly looks like up close,
        // rather than sharp-edged blocks that imply a resolution nobody has.
        maxNativeZoom: 6,
        tileBounds: tileBounds,
        tileProvider: NetworkTileProvider(httpClient: _tileClient),
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
        tileBuilder: (context, tileWidget, tile) {
          // Tiles are image DATA: under red night the enhanced tile goes
          // through the luminance -> red filter so the cloud structure
          // survives without emitting green or blue.
          return RedNightImage(
            child: _buildEnhancedTile(tileWidget, opacity, contrast),
          );
        },
      );
    } else {
      // Standard XYZ tile layer for RainViewer and similar services
      return TileLayer(
        urlTemplate: frame.tileUrlTemplate,
        // RainViewer only serves native tiles through zoom 7. Keep the map
        // itself zoomable and let flutter_map scale the zoom-7 radar tiles
        // instead of requesting the provider's "Zoom Level Not Supported"
        // placeholder tiles at the closer default map zooms.
        maxNativeZoom: 7,
        tileBounds: tileBounds,
        tileProvider: NetworkTileProvider(httpClient: _tileClient),
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
        tileBuilder: (context, tileWidget, tile) {
          // Tiles are image DATA: under red night the enhanced tile goes
          // through the luminance -> red filter so the cloud structure
          // survives without emitting green or blue.
          return RedNightImage(
            child: _buildEnhancedTile(tileWidget, opacity, contrast),
          );
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final userLocation = LatLng(widget.latitude, widget.longitude);

    // Build the map widget
    final mapWidget = FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: userLocation,
        initialZoom: _calculateInitialZoom(),
        minZoom: 4.0,
        maxZoom: 15.0,
        interactionOptions: InteractionOptions(
          flags: widget.compact
              ? InteractiveFlag.none // Disable interaction in compact mode
              // Enable all interactions EXCEPT scroll wheel zoom, which would
              // capture scroll events from the parent ScrollView and prevent
              // the page from scrolling when the cursor is over the map.
              // Users can still zoom via pinch, double-tap, or the +/- buttons.
              : InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom,
        ),
        onTap: widget.onTap != null ? (_, __) => widget.onTap?.call() : null,
      ),
      children: [
        // Base map layer (dark theme).
        //
        // NOT cartocdn: Carto now requires an API key for its basemaps and
        // serves the refusal as a watermark BAKED INTO an HTTP 200 tile
        // ("API KEY REQUIRED / carto.com/basemaps/apikey" across every image).
        // A 200 with a valid PNG body defeats every error path the map has,
        // so the whole radar view silently became a wall of watermarks with
        // nothing to report. Esri's dark-gray canvas is keyless, is the dark
        // ground this screen was designed against, and is attributed below.
        TileLayer(
          urlTemplate:
              'https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/'
              'World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: 'com.skotiq.app',
          // No retinaMode: it was correct for the old cartocdn template, whose
          // {r} placeholder let flutter_map request true @2x tiles from the
          // server. The Esri template has no {r}, so the flag would resolve to
          // RetinaMode.simulation — one zoom coarser, scaled up 2x — the same
          // trap documented on the WMS layer above.
          tileBuilder: (context, tileWidget, tile) {
            // Dim the base map for better radar visibility. As a ColorFilter
            // rather than an Opacity: an Opacity widget costs a saveLayer per
            // tile, and a tile is a single image draw so alpha-row scaling is
            // exact (see _buildTileFilter).
            return ColorFiltered(
              colorFilter: const ColorFilter.matrix(<double>[
                1,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                0,
                0,
                0.6,
                0,
              ]),
              // Image DATA, so red night re-emits its luminance on the red
              // axis. The dim above stays: it is what keeps the ground quiet
              // under the radar.
              child: RedNightImage(child: tileWidget),
            );
          },
        ),

        // Radar overlay layer - handles both XYZ and WMS tile types
        if (widget.currentFrame != null) ...[
          _buildRadarTileLayer(
            widget.currentFrame!,
            widget.radarOpacity,
            widget.contrastLevel,
          ),
        ],

        // Place names and boundaries, ABOVE the weather.
        //
        // Esri splits its canvas basemaps in two: "Base" is the ground alone —
        // no towns, no roads, no state lines — and "Reference" carries every
        // label. Shipping only the Base left the map underneath the clouds
        // showing nothing identifiable, so an operator could not tell what
        // part of the world the weather was over.
        //
        // It goes ON TOP of the radar deliberately. Underneath it would be
        // dimmed by the base layer's 0.6 and then covered by the radar's
        // opacity — about 18% of its brightness would survive, which is how
        // the labels were effectively invisible. Above the imagery they stay
        // readable at any radar opacity, which is the way weather maps
        // conventionally stack.
        TileLayer(
          urlTemplate:
              'https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/'
              'World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: 'com.skotiq.app',
          // No retinaMode — same reason as the base layer: no {r} in the Esri
          // template means the flag can only make the labels COARSER.
          tileBuilder: (context, tileWidget, tile) =>
              RedNightImage(child: tileWidget),
        ),

        // Alert radius circle
        CircleLayer(
          circles: [
            CircleMarker(
              point: userLocation,
              radius: widget.alertRadiusKm * 1000, // Convert km to meters
              useRadiusInMeter: true,
              color: colors.warning.withValues(alpha: 0.08),
              borderColor: colors.warning.withValues(alpha: 0.4),
              borderStrokeWidth: 2.0,
            ),
          ],
        ),

        // User location marker
        MarkerLayer(
          markers: [
            Marker(
              point: userLocation,
              width: 40,
              height: 40,
              alignment: Alignment.center,
              child: LocationMarker(colors: colors),
            ),
          ],
        ),

        // Cloud motion indicator (if provided)
        if (widget.motionDirection != null)
          MarkerLayer(
            markers: [
              Marker(
                point: userLocation,
                width: 60,
                height: 60,
                alignment: Alignment.center,
                child: MotionIndicator(
                  directionDegrees: widget.motionDirection!,
                  colors: colors,
                ),
              ),
            ],
          ),

        // The basemap's terms require its attribution to be shown wherever the
        // tiles are. The radar source names itself in its own overlay chip, so
        // this credits the ground the radar is drawn over.
        const RichAttributionWidget(
          alignment: AttributionAlignment.bottomRight,
          animationConfig: FadeRAWA(),
          attributions: [
            TextSourceAttribution('Esri, HERE, Garmin, © OpenStreetMap'),
          ],
        ),
      ],
    );

    // Wrap with controls if not compact
    if (widget.compact) {
      return ClipRRect(
        borderRadius: SkotiqTokens.borderRadiusLg,
        child: mapWidget,
      );
    }

    return Stack(
      children: [
        mapWidget,

        // Zoom group, bottom-right (05 §14 corner allocation). One glass
        // element, not three floating buttons.
        Positioned(
          right: SkotiqTokens.space2xl,
          bottom: SkotiqTokens.spaceLg,
          child: Glass(
            padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SkotiqIconButton(
                  icon: LucideIcons.minus,
                  tooltip: 'Zoom out',
                  size: IconButtonSize.sm,
                  onPressed: () => _mapController.move(
                    _mapController.camera.center,
                    math.max(_mapController.camera.zoom - 1, 4.0),
                  ),
                ),
                SkotiqIconButton(
                  icon: LucideIcons.plus,
                  tooltip: 'Zoom in',
                  size: IconButtonSize.sm,
                  onPressed: () => _mapController.move(
                    _mapController.camera.center,
                    math.min(_mapController.camera.zoom + 1, 15.0),
                  ),
                ),
                SkotiqIconButton(
                  icon: LucideIcons.locateFixed,
                  tooltip: 'Centre on your site',
                  size: IconButtonSize.sm,
                  onPressed: () => _mapController.move(
                      userLocation, _calculateInitialZoom()),
                ),
              ],
            ),
          ),
        ),

        // Source stamp, top-left.
        if (widget.currentFrame != null)
          Positioned(
            left: SkotiqTokens.space2xl,
            top: SkotiqTokens.spaceLg,
            child: Glass(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.currentFrame!.isForecast
                        ? LucideIcons.cloudRainWind
                        : LucideIcons.satellite,
                    size: SkotiqTokens.iconSm,
                    color: widget.currentFrame!.isForecast
                        ? colors.warning
                        : colors.textSecondary,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Readout(
                    value: widget.sourceName ??
                        (widget.currentFrame!.isForecast ? 'Forecast' : 'Live'),
                    label: widget.fetchedAt == null
                        ? 'Source'
                        : 'Updated ${_formatAge(widget.fetchedAt!)}',
                    size: ReadoutSize.sm,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Fixed metrics the Weather screen needs to lay its own glass out around the
/// map's: the zoom group owns the bottom-right corner, so the control bar has
/// to stop short of it.
class WeatherRadarMapMetrics {
  const WeatherRadarMapMetrics._();

  /// Three 28px icon buttons plus the glass padding either side.
  static const double zoomGroupWidth =
      3 * SkotiqTokens.iconButtonSizeSm + 2 * SkotiqTokens.spaceXs;
}
