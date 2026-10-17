import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import '../../../utils/coordinate_format_utils.dart';
import '../planetarium_screen.dart';

part 'search_header_parts/_filter_controls.dart';

class SearchHeader extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final TextEditingController controller;
  final ValueChanged<String> onSearch;

  /// Focus node for the search field, supplied by the host when something
  /// outside this widget has to put the caret in the field — the command bar's
  /// "Search ⌘K" button and its keyboard shortcut. Owned by the caller when
  /// non-null; otherwise this widget creates and disposes its own.
  final FocusNode? focusNode;

  /// Whether the floating result list belongs to this header.
  ///
  /// False when the host already renders the same results underneath it — the
  /// plan panel's Search tab does. Both drew at once: a narrow overlay painted
  /// over a wider list, the front one clipped mid-row and the back one's rows
  /// showing through the edges, with both reported to accessibility. The
  /// coordinate branch has no equivalent below and still opens.
  final bool showResultSuggestions;

  const SearchHeader({
    super.key,
    required this.colors,
    required this.controller,
    required this.onSearch,
    this.focusNode,
    this.showResultSuggestions = true,
  });

  @override
  ConsumerState<SearchHeader> createState() => _SearchHeaderState();
}

class _SearchHeaderState extends ConsumerState<SearchHeader> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  /// Fallback node used only when the host does not supply one.
  FocusNode? _ownedFocusNode;
  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  Timer? _debounceTimer;
  CelestialCoordinate? _parsedCoordinate;
  bool _showFilters = false;

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      _showOverlay();
    } else {
      _hideOverlay();
    }
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _hideOverlay();
    // Only the fallback node is ours to dispose; a host-supplied node outlives
    // this widget (the plan panel is unmounted whenever it is closed).
    _focusNode.removeListener(_onFocusChanged);
    _ownedFocusNode?.dispose();
    _debounceTimer?.cancel();
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  /// Parse coordinate input like "RA 5h 35m, Dec -5d 23'"
  CelestialCoordinate? _parseCoordinates(String input) {
    // Try pattern like "RA 5h 35m, Dec -5d 23'" or "RA 5h 35m Dec -5 23"
    final pattern = RegExp(
      r"^\s*RA\s*(\d+)\s*h\s*(\d+)\s*m?\s*,?\s*Dec\s*([+-]?)\s*(\d+)\s*[°d]?\s*(\d+)\s*['m]?\s*$",
      caseSensitive: false,
    );
    final match = pattern.firstMatch(input);

    if (match != null) {
      final ra = CoordinateParser.parseRa(
        '${match.group(1)}:${match.group(2)}:0',
      );
      final dec = CoordinateParser.parseDec(
        '${match.group(3)}${match.group(4)}:${match.group(5)}:0',
      );
      if (ra == null || dec == null) return null;

      return CelestialCoordinate(ra: ra, dec: dec);
    }
    return null;
  }

  void _onTextChanged() {
    // Cancel previous debounce timer
    _debounceTimer?.cancel();

    // Check for coordinate input first
    _parsedCoordinate = _parseCoordinates(widget.controller.text);
    if (_parsedCoordinate != null) {
      // If coordinates were parsed, show overlay immediately
      _showOverlay();
      return;
    }

    if (widget.controller.text.length >= 2) {
      // Debounce search by 250ms for instant results as user types
      _debounceTimer = Timer(const Duration(milliseconds: 250), () {
        if (mounted) {
          ref
              .read(objectSearchProvider.notifier)
              .search(widget.controller.text);
          _showOverlay();
        }
      });
    } else {
      _hideOverlay();
    }
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;

    // Don't show if query is too short (unless we have parsed coordinates)
    if (widget.controller.text.length < 2 && _parsedCoordinate == null) return;
    if (!widget.showResultSuggestions && _parsedCoordinate == null) return;

    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) {
        final overlayWidth = _layerLink.leaderSize?.width ??
            Responsive.previewOverlayMaxWidth(
              MediaQuery.sizeOf(context).width,
              maxAbsolute: 308,
            );
        final maxOverlayHeight = math.min(
          450.0,
          MediaQuery.sizeOf(context).height * 0.45,
        );
        return Positioned(
          width: overlayWidth,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: const Offset(0, 46), // Height of text field + padding
            child: Material(
              elevation: 8,
              color: widget.colors.surface,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: widget.colors.border),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  color: widget.colors.surface,
                ),
                constraints: BoxConstraints(maxHeight: maxOverlayHeight),
                child: Consumer(
                  builder: (context, ref, child) {
                    // Check for parsed coordinates first
                    if (_parsedCoordinate != null) {
                      final coord = _parsedCoordinate!;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SearchCategoryHeader(
                            title: 'Coordinates',
                            icon: SkotiqIcons.compass,
                            colors: widget.colors,
                          ),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                // Smoothly fly to the parsed coordinates.
                                ref
                                    .read(flyToRequestProvider.notifier)
                                    .flyTo(coord);
                                _hideOverlay();
                                _focusNode.unfocus();
                              },
                              child: ListTile(
                                dense: true,
                                leading: Container(
                                  width: 32,
                                  height: 32,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: widget.colors.accent
                                        .withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(
                                        SkotiqTokens.radiusInline4),
                                  ),
                                  child: Icon(
                                    SkotiqIcons.crosshair,
                                    size: 16,
                                    color: widget.colors.accent,
                                  ),
                                ),
                                title: Text(
                                  'Go to coordinates',
                                  style: TextStyle(
                                      color: widget.colors.textPrimary),
                                ),
                                subtitle: Text(
                                  'RA ${CoordinateFormatUtils.formatRACompact(coord.ra)}, Dec ${CoordinateFormatUtils.formatDec(coord.dec)}',
                                  style: TextStyle(
                                      color: widget.colors.textMuted,
                                      fontSize: SkotiqTypography.fontSize11),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }

                    final searchState = ref.watch(objectSearchProvider);

                    if (searchState.isSearching) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16.0),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }

                    if (searchState.results.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          'No results found',
                          style: TextStyle(color: widget.colors.textMuted),
                        ),
                      );
                    }

                    // Show all results grouped by category, no hardcoded limit.
                    // Solar-system bodies are wrapped as Star objects with
                    // PLANET_/MINORBODY_ ids by the search resolver; split them
                    // out so they get their own group instead of mixing with
                    // catalog stars.
                    final allStars =
                        searchState.results.whereType<Star>().toList();
                    final solarSystem =
                        allStars.where(_isSolarSystemBody).toList();
                    final stars =
                        allStars.where((s) => !_isSolarSystemBody(s)).toList();
                    final dsos =
                        searchState.results.whereType<DeepSkyObject>().toList();

                    if (stars.isEmpty && dsos.isEmpty && solarSystem.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          'No results found',
                          style: TextStyle(color: widget.colors.textMuted),
                        ),
                      );
                    }

                    // Show result count
                    final totalCount =
                        stars.length + dsos.length + solarSystem.length;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Result count header
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color:
                                widget.colors.surfaceAlt.withValues(alpha: 0.3),
                            border: Border(
                                bottom: BorderSide(
                                    color: widget.colors.border
                                        .withValues(alpha: 0.5))),
                          ),
                          child: Row(
                            children: [
                              Text(
                                '$totalCount result${totalCount == 1 ? '' : 's'}',
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize10,
                                  color: widget.colors.textMuted,
                                ),
                              ),
                              if (searchState.filters.hasActiveFilters) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: widget.colors.accent
                                        .withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(
                                        SkotiqTokens.radiusXs),
                                  ),
                                  child: Text(
                                    'filtered',
                                    style: TextStyle(
                                      fontSize: SkotiqTypography.fontSize9,
                                      color: widget.colors.accent,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Flexible(
                          child: ListView(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            children: [
                              // Solar System section (planets, comets, asteroids)
                              if (solarSystem.isNotEmpty) ...[
                                SearchCategoryHeader(
                                  title: 'Solar System (${solarSystem.length})',
                                  icon: SkotiqIcons.sun,
                                  colors: widget.colors,
                                ),
                                ...solarSystem.map((body) =>
                                    _buildSolarSystemResultTile(ref, body)),
                              ],
                              // DSO section
                              if (dsos.isNotEmpty) ...[
                                SearchCategoryHeader(
                                  title: 'Deep Sky Objects (${dsos.length})',
                                  icon: SkotiqIcons.sparkle,
                                  colors: widget.colors,
                                ),
                                // Show first 20 DSOs in overlay, full list in Search tab
                                ...dsos.take(20).map(
                                    (dso) => _buildDsoResultTile(ref, dso)),
                                if (dsos.length > 20)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    child: Text(
                                      '${dsos.length - 20} more in Search tab...',
                                      style: TextStyle(
                                        fontSize: SkotiqTypography.fontSize11,
                                        color: widget.colors.textMuted,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ),
                              ],
                              // Stars section
                              if (stars.isNotEmpty) ...[
                                SearchCategoryHeader(
                                  title: 'Stars (${stars.length})',
                                  icon: SkotiqIcons.star,
                                  colors: widget.colors,
                                ),
                                ...stars.take(10).map(
                                    (star) => _buildStarResultTile(ref, star)),
                                if (stars.length > 10)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    child: Text(
                                      '${stars.length - 10} more in Search tab...',
                                      style: TextStyle(
                                        fontSize: SkotiqTypography.fontSize11,
                                        color: widget.colors.textMuted,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(_overlayEntry!);
  }

  Widget _buildDsoResultTile(WidgetRef ref, DeepSkyObject dso) {
    final info = getDsoDisplayInfo(dso);
    final displayName = info.$1;
    final catalogTag = info.$2;
    // Show common name as subtitle if different from display name
    final commonName = dso.commonNames?.split(',').first.trim();
    final showCommonName = commonName != null &&
        commonName.isNotEmpty &&
        commonName != displayName;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ref.read(selectedObjectProvider.notifier).selectObject(dso);
          ref.read(flyToRequestProvider.notifier).flyTo(dso.coordinates);
          // Deliberately does NOT re-run the query on the picked object's
          // name: that replaced the typed query's results (typing "6720" then
          // picking M57 left the sidebar listing matches for "M57" while the
          // field still read "6720"), so backing out of a wrong pick landed in
          // a list the user never asked for.
          _hideOverlay();
          _focusNode.unfocus();
        },
        child: ListTile(
          dense: true,
          leading: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            ),
            child: Text(
              catalogTag,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                fontWeight: FontWeight.bold,
                color: widget.colors.primary,
              ),
            ),
          ),
          title: Text(
            displayName,
            style: TextStyle(color: widget.colors.textPrimary),
          ),
          subtitle: Text(
            showCommonName
                ? '$commonName - ${dso.type.displayName}'
                : dso.type.displayName,
            style: TextStyle(
                color: widget.colors.textMuted,
                fontSize: SkotiqTypography.fontSize11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: dso.magnitude != null
              ? Text(
                  'mag ${dso.magnitude!.toStringAsFixed(1)}',
                  style: TextStyle(
                      color: widget.colors.textMuted,
                      fontSize: SkotiqTypography.fontSize11),
                )
              : null,
        ),
      ),
    );
  }

  /// True if [star] is a solar-system body wrapped by the search resolver.
  ///
  /// Asks the type rather than sniffing the `PLANET_`/`MINORBODY_` id prefix:
  /// the prefix is an internal join key and duplicating knowledge of it here is
  /// what let a planet be treated as a star everywhere that did not remember to
  /// check.
  static bool _isSolarSystemBody(Star star) => star is SolarSystemBody;

  Widget _buildSolarSystemResultTile(WidgetRef ref, Star body) {
    final isPlanet =
        body is SolarSystemBody && body.kind == SolarSystemBodyKind.planet;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ref.read(selectedObjectProvider.notifier).selectObject(body);
          ref.read(flyToRequestProvider.notifier).flyTo(body.coordinates);
          // See _buildDsoResultTile: picking a result must not rewrite the
          // query the user typed.
          _hideOverlay();
          _focusNode.unfocus();
        },
        child: ListTile(
          dense: true,
          leading: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.colors.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            ),
            child: Icon(
              isPlanet ? SkotiqIcons.globe : SkotiqIcons.sparkle,
              size: 16,
              color: widget.colors.accent,
            ),
          ),
          title: Text(
            body.name,
            style: TextStyle(color: widget.colors.textPrimary),
          ),
          subtitle: Text(
            isPlanet ? 'Planet' : 'Comet / Asteroid',
            style: TextStyle(
                color: widget.colors.textMuted,
                fontSize: SkotiqTypography.fontSize11),
          ),
          trailing: body.magnitude != null
              ? Text(
                  'mag ${body.magnitude!.toStringAsFixed(1)}',
                  style: TextStyle(
                      color: widget.colors.textMuted,
                      fontSize: SkotiqTypography.fontSize11),
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildStarResultTile(WidgetRef ref, Star star) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ref.read(selectedObjectProvider.notifier).selectObject(star);
          ref.read(flyToRequestProvider.notifier).flyTo(star.coordinates);
          // See _buildDsoResultTile: picking a result must not rewrite the
          // query the user typed.
          _hideOverlay();
          _focusNode.unfocus();
        },
        child: ListTile(
          dense: true,
          leading: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            ),
            child: Text(
              '\u2605',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize14,
                color: widget.colors.warning,
              ),
            ),
          ),
          title: Text(
            star.name,
            style: TextStyle(color: widget.colors.textPrimary),
          ),
          subtitle: Text(
            star.constellation != null
                ? 'Star - ${star.constellation}'
                : 'Star',
            style: TextStyle(
                color: widget.colors.textMuted,
                fontSize: SkotiqTypography.fontSize11),
          ),
          trailing: star.magnitude != null
              ? Text(
                  'mag ${star.magnitude!.toStringAsFixed(1)}',
                  style: TextStyle(
                      color: widget.colors.textMuted,
                      fontSize: SkotiqTypography.fontSize11),
                )
              : null,
        ),
      ),
    );
  }

  /// Enter/submit handler: fly to parsed coordinates if the query is a
  /// coordinate, otherwise resolve the best-matching object across all catalogs
  /// (planets/comets/asteroids included) and fly to + select it.
  Future<void> _flyToBestMatch(String value) async {
    if (value.trim().isEmpty) return;
    widget.onSearch(value);

    final coord = _parseCoordinates(value);
    if (coord != null) {
      ref.read(flyToRequestProvider.notifier).flyTo(coord);
      _hideOverlay();
      _focusNode.unfocus();
      return;
    }

    final best =
        await ref.read(objectSearchProvider.notifier).resolveBest(value);
    if (!mounted || best == null) {
      _hideOverlay();
      return;
    }

    ref.read(selectedObjectProvider.notifier).selectObject(best);
    ref.read(flyToRequestProvider.notifier).flyTo(best.coordinates);
    _hideOverlay();
    _focusNode.unfocus();
  }

  void _hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(objectSearchProvider);
    final filters = searchState.filters;

    final phone = Responsive.isPhone(context);
    return Container(
      padding: EdgeInsets.all(phone ? 8 : 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: widget.colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Search field row
          Row(
            children: [
              Expanded(
                child: CompositedTransformTarget(
                  link: _layerLink,
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize13,
                        color: widget.colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Search objects, names...',
                      hintStyle: TextStyle(
                          fontSize: SkotiqTypography.fontSize13,
                          color: widget.colors.textMuted),
                      prefixIcon: Icon(SkotiqIcons.search,
                          size: 16, color: widget.colors.textMuted),
                      suffixIcon: Container(
                        margin: const EdgeInsets.all(8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: widget.colors.background,
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusInline4),
                        ),
                        child: Text(
                          shortcutLabel('K'),
                          style: TextStyle(
                              fontSize: SkotiqTypography.fontSize10,
                              color: widget.colors.textMuted),
                        ),
                      ),
                      filled: true,
                      fillColor: widget.colors.surfaceAlt,
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusInline8),
                        borderSide: BorderSide(color: widget.colors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusInline8),
                        borderSide: BorderSide(color: widget.colors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusInline8),
                        borderSide: BorderSide(color: widget.colors.primary),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                    onSubmitted: (value) {
                      _flyToBestMatch(value);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Filter toggle button
              GestureDetector(
                onTap: () => setState(() => _showFilters = !_showFilters),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: filters.hasActiveFilters
                        ? widget.colors.accent.withValues(alpha: 0.2)
                        : widget.colors.surfaceAlt,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    border: Border.all(
                      color: filters.hasActiveFilters
                          ? widget.colors.accent.withValues(alpha: 0.5)
                          : widget.colors.border,
                    ),
                  ),
                  child: Icon(
                    LucideIcons.slidersHorizontal,
                    size: 14,
                    color: filters.hasActiveFilters
                        ? widget.colors.accent
                        : widget.colors.textMuted,
                  ),
                ),
              ),
            ],
          ),

          // Filter controls (collapsible)
          if (_showFilters) ...[
            const SizedBox(height: 12),
            _SearchFilterControls(
              colors: widget.colors,
              filters: filters,
              onFiltersChanged: (newFilters) {
                ref
                    .read(objectSearchProvider.notifier)
                    .updateFilters(newFilters);
              },
            ),
          ],
        ],
      ),
    );
  }
}
