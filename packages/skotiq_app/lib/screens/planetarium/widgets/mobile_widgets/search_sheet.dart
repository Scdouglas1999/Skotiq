part of '../mobile_widgets.dart';

class MobileSearchSheet extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final ScrollController scrollController;
  final ValueChanged<CelestialObject> onObjectSelected;

  const MobileSearchSheet({
    super.key,
    required this.colors,
    required this.scrollController,
    required this.onObjectSelected,
  });

  @override
  ConsumerState<MobileSearchSheet> createState() => _MobileSearchSheetState();
}

class _MobileSearchSheetState extends ConsumerState<MobileSearchSheet> {
  final _searchController = TextEditingController();
  Timer? _debounceTimer;

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    if (mounted) setState(() {});
    if (value.length >= 2) {
      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        ref.read(objectSearchProvider.notifier).search(value);
      });
    } else {
      // A one-character query cannot be searched. Drop the previous query's
      // results instead of displaying them under unrelated input.
      ref.read(objectSearchProvider.notifier).clear();
    }
  }

  void _clearSearch() {
    _debounceTimer?.cancel();
    _searchController.clear();
    ref.read(objectSearchProvider.notifier).clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(objectSearchProvider);

    return Column(
      children: [
        // Search input
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            autofocus: true,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize14,
                color: widget.colors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Search objects (M42, Orion, etc.)',
              hintStyle: TextStyle(
                  fontSize: SkotiqTypography.fontSize14,
                  color: widget.colors.textMuted),
              prefixIcon: Icon(SkotiqIcons.search,
                  size: 18, color: widget.colors.textMuted),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(SkotiqIcons.close,
                          size: 18, color: widget.colors.textMuted),
                      tooltip: 'Clear search',
                      onPressed: _clearSearch,
                    )
                  : null,
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
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            onChanged: _onSearchChanged,
          ),
        ),

        // Results
        Expanded(
          child: _buildResults(searchState),
        ),
      ],
    );
  }

  Widget _buildResults(ObjectSearchState searchState) {
    if (_searchController.text.isEmpty) {
      // Show quick picks when no search
      return _buildQuickPicks();
    }

    if (searchState.isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (searchState.results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(SkotiqIcons.searchEmpty,
                size: 48, color: widget.colors.textMuted),
            const SizedBox(height: 16),
            Text(
              'No results found',
              style: TextStyle(color: widget.colors.textMuted),
            ),
          ],
        ),
      );
    }

    final tileExtent = _mobileSearchTileExtent(context);

    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemExtent: tileExtent,
      itemCount: searchState.results.length,
      itemBuilder: (context, index) {
        final obj = searchState.results[index];
        return MobileSearchResultTile(
          object: obj,
          colors: widget.colors,
          onTap: () => widget.onObjectSelected(obj),
        );
      },
    );
  }

  Widget _buildQuickPicks() {
    final bestTargets = ref.watch(bestTargetsProvider);

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Text(
          'Best Targets Tonight',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize12,
            fontWeight: FontWeight.w600,
            color: widget.colors.textMuted,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 12),
        bestTargets.when(
          data: (targets) {
            // Ranking tonight's targets is a per-site computation, so with no
            // site there is no list — a different answer from an empty one.
            if (targets == null) {
              return Container(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'Set an observing location to rank tonight\u2019s targets',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: widget.colors.textMuted),
                  ),
                ),
              );
            }
            if (targets.isEmpty) {
              return Container(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'Nothing clears 30° during tonight’s darkness',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: widget.colors.textMuted),
                  ),
                ),
              );
            }
            return Column(
              children: targets.take(10).map((item) {
                return MobileSearchResultTile(
                  object: item.object,
                  colors: widget.colors,
                  onTap: () => widget.onObjectSelected(item.object),
                );
              }).toList(),
            );
          },
          // Shimmer tile column instead of a spinner so the search panel
          // doesn't visibly shrink while suggestions stream in.
          loading: () => Column(
            children: List.generate(
              5,
              (_) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ShimmerLoading(
                  child: Container(
                    height: _mobileSearchTileExtent(context) - 12,
                    decoration: BoxDecoration(
                      color: widget.colors.surfaceAlt,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusMd),
                    ),
                  ),
                ),
              ),
            ),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Could not load tonight’s targets',
                textAlign: TextAlign.center,
                style: TextStyle(color: widget.colors.textMuted),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Mobile search result tile
class MobileSearchResultTile extends StatelessWidget {
  final CelestialObject object;
  final SkotiqColors colors;
  final VoidCallback onTap;

  const MobileSearchResultTile({
    super.key,
    required this.object,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final avatarSize = _mobileTouchOuter(context) * 0.82;

    String displayName;
    String catalogTag;
    String typeName;

    if (object is DeepSkyObject) {
      final info = getDsoDisplayInfo(object as DeepSkyObject);
      displayName = info.$1;
      catalogTag = info.$2;
      typeName = (object as DeepSkyObject).type.displayName;
    } else if (object is Star) {
      displayName = object.name;
      catalogTag = 'STAR';
      typeName = 'Star';
    } else {
      displayName = object.name;
      catalogTag = object.id;
      typeName = 'Object';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SkotiqCard(
        onTap: onTap,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: avatarSize,
              height: avatarSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.15),
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Text(
                catalogTag,
                style: TextStyle(
                  fontSize: avatarSize * 0.25,
                  fontWeight: FontWeight.bold,
                  color: colors.primary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.h5
                        .copyWith(color: colors.textPrimary),
                  ),
                  Text(
                    typeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (object.magnitude != null)
              Text(
                'mag ${object.magnitude!.toStringAsFixed(1)}',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textSecondary,
                ),
              ),
            const SizedBox(width: 8),
            Icon(
              SkotiqIcons.chevronRight,
              size: 16,
              color: colors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// Compass calibration dialog shown on first gyroscope activation.
