import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../dashboard_layout.dart';
import 'dashboard_tile.dart';
import 'dashboard_widget_registry.dart';

/// Column of widgets for a specific zone.
class DashboardZoneColumn extends StatelessWidget {
  final DashboardZone zone;
  final List<DashboardTileConfig> tiles;
  final Map<DashboardWidgetId, DashboardWidgetDefinition> registry;
  final SkotiqColors colors;
  final AnimationController pulseController;
  final bool isEditing;
  final CardVariant cardVariant;
  final bool isHeroZone;
  final void Function(DashboardWidgetId dragged, DashboardWidgetId target)
      onReorder;
  final void Function(DashboardWidgetId id) onResize;
  final void Function(DashboardWidgetId id, bool enabled) onToggleEnabled;

  const DashboardZoneColumn({
    super.key,
    required this.zone,
    required this.tiles,
    required this.registry,
    required this.colors,
    required this.pulseController,
    required this.isEditing,
    required this.cardVariant,
    required this.isHeroZone,
    required this.onReorder,
    required this.onResize,
    required this.onToggleEnabled,
  });

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) {
      return _EmptyZonePlaceholder(
          zone: zone, colors: colors, isEditing: isEditing);
    }

    // Use tighter spacing for secondary zone (8px) vs primary (16px)
    final gapHeight = zone == DashboardZone.secondary ? 8.0 : 16.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          _buildZoneTile(tiles[i], i == 0 && isHeroZone),
          if (i < tiles.length - 1) SizedBox(height: gapHeight),
        ],
      ],
    );
  }

  Widget _buildZoneTile(DashboardTileConfig tile, bool isHero) {
    final definition = registry[tile.widgetId];
    if (definition == null) {
      return DashboardLayoutError(
        title: 'Unknown widget',
        buttonLabel: 'Hide Tile',
        error: 'Missing widget definition for ${tile.widgetId.storageKey}.',
        onReset: () => onToggleEnabled(tile.widgetId, false),
      );
    }

    final child = Builder(
      builder: (context) =>
          definition.builder(context, colors, pulseController),
    );

    return DashboardTile(
      tile: tile,
      width: double.infinity,
      colors: colors,
      isEditing: isEditing,
      cardVariant: isHero ? CardVariant.elevated : cardVariant,
      isHero: isHero,
      selfChromed: definition.selfChromed,
      onReorder: onReorder,
      onResize: onResize,
      onToggleEnabled: onToggleEnabled,
      child: child,
    );
  }
}

/// Placeholder for empty zones in edit mode.
class _EmptyZonePlaceholder extends StatelessWidget {
  final DashboardZone zone;
  final SkotiqColors colors;
  final bool isEditing;

  const _EmptyZonePlaceholder({
    required this.zone,
    required this.colors,
    required this.isEditing,
  });

  @override
  Widget build(BuildContext context) {
    if (!isEditing) return const SizedBox.shrink();

    final zoneName = switch (zone) {
      DashboardZone.primary => 'Primary',
      DashboardZone.secondary => 'Secondary',
      DashboardZone.tertiary => 'Tertiary',
    };

    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: colors.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(
          color: colors.border,
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.layoutGrid, size: 32, color: colors.textMuted),
          const SizedBox(height: 12),
          Text(
            '$zoneName Zone',
            style: SkotiqTypography.button
                .copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            'Enable widgets to add them here',
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Mobile equipment section with responsive wrap layout.
///
/// Displays equipment-related cards (Equipment Status, Mount Control, Focus) in a
/// flexible wrap layout that adapts to available width:
/// - On narrow screens: cards stack vertically (single column)
/// - On wider mobile screens: cards flow in a 2-column wrap
class MobileEquipmentSection extends StatelessWidget {
  final List<DashboardTileConfig> tiles;
  final Map<DashboardWidgetId, DashboardWidgetDefinition> registry;
  final SkotiqColors colors;
  final AnimationController pulseController;
  final bool isEditing;
  final void Function(DashboardWidgetId dragged, DashboardWidgetId target)
      onReorder;
  final void Function(DashboardWidgetId id) onResize;
  final void Function(DashboardWidgetId id, bool enabled) onToggleEnabled;

  const MobileEquipmentSection({
    super.key,
    required this.tiles,
    required this.registry,
    required this.colors,
    required this.pulseController,
    required this.isEditing,
    required this.onReorder,
    required this.onResize,
    required this.onToggleEnabled,
  });

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        // Use wrap layout for cards - 2 columns if width >= 400, otherwise single column
        final useWrap = availableWidth >= 400;
        final cardWidth = useWrap ? (availableWidth - 12) / 2 : availableWidth;

        if (useWrap) {
          // Wrap layout for wider mobile screens
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: tiles.map((tile) {
              return SizedBox(
                width: cardWidth,
                child: _buildEquipmentTile(tile),
              );
            }).toList(),
          );
        } else {
          // Stack vertically for narrow screens
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                _buildEquipmentTile(tiles[i]),
                if (i < tiles.length - 1) const SizedBox(height: 12),
              ],
            ],
          );
        }
      },
    );
  }

  Widget _buildEquipmentTile(DashboardTileConfig tile) {
    final definition = registry[tile.widgetId];
    if (definition == null) return const SizedBox.shrink();

    final child = Builder(
      builder: (context) =>
          definition.builder(context, colors, pulseController),
    );

    return DashboardTile(
      tile: tile,
      width: double.infinity,
      colors: colors,
      isEditing: isEditing,
      cardVariant: CardVariant.standard,
      isHero: false,
      selfChromed: definition.selfChromed,
      onReorder: onReorder,
      onResize: onResize,
      onToggleEnabled: onToggleEnabled,
      child: child,
    );
  }
}

/// Tertiary zone displayed as a horizontal row of compact cards.
/// Uses ConsumerWidget to conditionally hide the Alerts card when empty.
class TertiaryZoneRow extends ConsumerWidget {
  final List<DashboardTileConfig> tiles;
  final Map<DashboardWidgetId, DashboardWidgetDefinition> registry;
  final SkotiqColors colors;
  final AnimationController pulseController;
  final bool isEditing;
  final void Function(DashboardWidgetId dragged, DashboardWidgetId target)
      onReorder;
  final void Function(DashboardWidgetId id) onResize;
  final void Function(DashboardWidgetId id, bool enabled) onToggleEnabled;

  /// Fixed minimum height for all tertiary zone cards to ensure consistent layout.
  static const double _tertiaryCardMinHeight = 150.0;

  /// Minimum width for tertiary cards.
  static const double _minCardWidth = 200.0;

  /// Maximum width for tertiary cards.
  static const double _maxCardWidth = 400.0;

  /// Spacing between cards.
  static const double _cardSpacing = 12.0;

  const TertiaryZoneRow({
    super.key,
    required this.tiles,
    required this.registry,
    required this.colors,
    required this.pulseController,
    required this.isEditing,
    required this.onReorder,
    required this.onResize,
    required this.onToggleEnabled,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Check if alerts card should be hidden (no notifications and no active operation)
    final notifications = ref.watch(uiNotificationProvider);
    final hasOperation = ref.watch(hasActiveOperationProvider);
    final alertsHasContent = notifications.isNotEmpty || hasOperation;

    // Filter out Alerts card if it has no content (unless in edit mode where we show all)
    final filteredTiles = tiles.where((tile) {
      if (tile.widgetId == DashboardWidgetId.alerts &&
          !alertsHasContent &&
          !isEditing) {
        return false;
      }
      return true;
    }).toList();

    if (filteredTiles.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final cardCount = filteredTiles.length;

        // Calculate optimal layout
        final layout = _calculateCardLayout(availableWidth, cardCount);

        // Build rows of cards
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _buildCardRows(filteredTiles, layout),
        );
      },
    );
  }

  /// Calculate the optimal card layout based on available width and card count.
  /// Returns a record with (cardWidth, cardsPerRow).
  ({double cardWidth, int cardsPerRow}) _calculateCardLayout(
    double availableWidth,
    int totalCards,
  ) {
    if (totalCards == 0) {
      return (cardWidth: _minCardWidth, cardsPerRow: 1);
    }

    // Try fitting all cards in one row first
    // Available width for cards = total width - spacing between cards
    // For N cards: spacing = (N - 1) * _cardSpacing
    double calculateCardWidth(int cardsInRow) {
      if (cardsInRow <= 0) return _maxCardWidth;
      final totalSpacing = (cardsInRow - 1) * _cardSpacing;
      return (availableWidth - totalSpacing) / cardsInRow;
    }

    // Start with trying to fit all cards in one row
    int cardsPerRow = totalCards;
    double cardWidth = calculateCardWidth(cardsPerRow);

    // If cards would be too narrow, reduce cards per row until they fit
    while (cardWidth < _minCardWidth && cardsPerRow > 1) {
      cardsPerRow--;
      cardWidth = calculateCardWidth(cardsPerRow);
    }

    // On very narrow screens (mobile), allow full width even if below min
    // This prevents horizontal overflow on small devices
    if (cardsPerRow == 1) {
      cardWidth = availableWidth; // Full width for single column
    } else {
      // Clamp to max width (cards won't exceed max even if there's extra space)
      cardWidth = cardWidth.clamp(_minCardWidth, _maxCardWidth);
    }

    return (cardWidth: cardWidth, cardsPerRow: cardsPerRow);
  }

  /// Build rows of cards with equal widths within each row.
  List<Widget> _buildCardRows(
    List<DashboardTileConfig> tiles,
    ({double cardWidth, int cardsPerRow}) layout,
  ) {
    final rows = <Widget>[];
    final totalCards = tiles.length;
    int startIndex = 0;

    while (startIndex < totalCards) {
      final remainingCards = totalCards - startIndex;
      final cardsInThisRow = remainingCards < layout.cardsPerRow
          ? remainingCards
          : layout.cardsPerRow;

      // Get tiles for this row
      final rowTiles = tiles.sublist(startIndex, startIndex + cardsInThisRow);

      // For the last row with fewer cards, we still want equal-width cards
      // but they should expand to fill the row (up to max width each)
      final rowWidget =
          _buildSingleRow(rowTiles, layout.cardWidth, layout.cardsPerRow);

      if (rows.isNotEmpty) {
        rows.add(const SizedBox(height: _cardSpacing));
      }
      rows.add(rowWidget);

      startIndex += cardsInThisRow;
    }

    return rows;
  }

  /// Build a single row of cards.
  Widget _buildSingleRow(
    List<DashboardTileConfig> rowTiles,
    double baseCardWidth,
    int standardCardsPerRow,
  ) {
    // Use Row with Expanded children to distribute space evenly
    // Cards have a fixed minHeight via _tertiaryCardMinHeight for consistent layout
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < rowTiles.length; i++) ...[
          if (i > 0) const SizedBox(width: _cardSpacing),
          Expanded(
            child: _buildTertiaryTile(rowTiles[i]),
          ),
        ],
      ],
    );
  }

  Widget _buildTertiaryTile(DashboardTileConfig tile) {
    final definition = registry[tile.widgetId];
    if (definition == null) return const SizedBox.shrink();

    final child = Builder(
      builder: (context) =>
          definition.builder(context, colors, pulseController),
    );

    // Wrap in ConstrainedBox with minHeight for consistent card sizing
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _tertiaryCardMinHeight),
      child: DashboardTile(
        tile: tile,
        width: double.infinity,
        colors: colors,
        isEditing: isEditing,
        cardVariant: CardVariant.standard,
        isHero: false,
        selfChromed: definition.selfChromed,
        onReorder: onReorder,
        onResize: onResize,
        onToggleEnabled: onToggleEnabled,
        child: child,
      ),
    );
  }
}
