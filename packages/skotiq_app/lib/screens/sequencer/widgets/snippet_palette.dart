import 'dart:ui';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../utils/exported_file_reveal.dart';
import '../../accessible_dropdown.dart';

part 'snippet_palette/rendering.dart';
part 'snippet_palette/actions.dart';
part 'snippet_palette/category_section.dart';
part 'snippet_palette/draggable_item.dart';

/// Palette widget for displaying and managing template snippets.
///
/// Allows users to drag-and-drop pre-built or custom snippet templates
/// into their sequence, as well as create new snippets from selected nodes.
class SnippetPalette extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final bool isCollapsed;
  final VoidCallback? onToggleCollapse;
  final Function(TemplateSnippet)? onSnippetDragStart;
  final Function(TemplateSnippet)? onSnippetTap;
  final ScrollController? scrollController;
  final bool isMobileSheet;

  const SnippetPalette({
    super.key,
    required this.colors,
    this.isCollapsed = false,
    this.onToggleCollapse,
    this.onSnippetDragStart,
    this.onSnippetTap,
    this.scrollController,
    this.isMobileSheet = false,
  });

  @override
  ConsumerState<SnippetPalette> createState() => _SnippetPaletteState();
}

class _SnippetPaletteState extends ConsumerState<SnippetPalette> {
  String _searchQuery = '';
  final _searchController = TextEditingController();
  bool _isSnippetFileActionRunning = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // These single-flight guards live on the State (not the actions extension)
  // because setState is a protected State member — calling it from the
  // extension trips INVALID_USE_OF_PROTECTED_MEMBER.
  bool _beginSnippetFileAction() {
    if (_isSnippetFileActionRunning) return false;
    setState(() => _isSnippetFileActionRunning = true);
    return true;
  }

  void _finishSnippetFileAction() {
    if (mounted) {
      setState(() => _isSnippetFileActionRunning = false);
    } else {
      _isSnippetFileActionRunning = false;
    }
  }

  IconData _getIcon(String iconName) {
    switch (iconName) {
      case 'focus':
        return LucideIcons.focus;
      case 'palette':
        return LucideIcons.palette;
      case 'move':
        return LucideIcons.move;
      case 'shield':
        return LucideIcons.shield;
      case 'rotate-cw':
        return LucideIcons.rotateCw;
      case 'filter':
        return LucideIcons.filter;
      case 'camera':
        return LucideIcons.camera;
      case 'target':
        return LucideIcons.target;
      case 'clock':
        return LucideIcons.clock;
      case 'settings':
        return LucideIcons.settings;
      case 'star':
        return LucideIcons.star;
      case 'zap':
        return LucideIcons.zap;
      case 'layers':
        return LucideIcons.layers;
      case 'repeat':
        return LucideIcons.repeat;
      case 'grid':
        return LucideIcons.grid;
      default:
        return LucideIcons.puzzle;
    }
  }

  String _getCategoryDisplayName(SnippetCategory category) {
    switch (category) {
      case SnippetCategory.autofocus:
        return 'Autofocus';
      case SnippetCategory.dithering:
        return 'Dithering';
      case SnippetCategory.filterSequence:
        return 'Filter Sequences';
      case SnippetCategory.calibration:
        return 'Calibration';
      case SnippetCategory.safety:
        return 'Safety';
      case SnippetCategory.custom:
        return 'Custom';
    }
  }

  IconData _getCategoryIcon(SnippetCategory category) {
    switch (category) {
      case SnippetCategory.autofocus:
        return LucideIcons.focus;
      case SnippetCategory.dithering:
        return LucideIcons.move;
      case SnippetCategory.filterSequence:
        return LucideIcons.palette;
      case SnippetCategory.calibration:
        return LucideIcons.rotateCw;
      case SnippetCategory.safety:
        return LucideIcons.shield;
      case SnippetCategory.custom:
        return LucideIcons.puzzle;
    }
  }

  Color _getCategoryColor(SnippetCategory category) {
    switch (category) {
      case SnippetCategory.autofocus:
        return widget.colors.accent;
      case SnippetCategory.dithering:
        return widget.colors.info;
      case SnippetCategory.filterSequence:
        return widget.colors.primary;
      case SnippetCategory.calibration:
        return widget.colors.warning;
      case SnippetCategory.safety:
        return widget.colors.success;
      case SnippetCategory.custom:
        return widget.colors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snippetsByCategory = ref.watch(snippetsByCategoryProvider);

    // Filter snippets based on search query. Lower-case the query once up
    // front rather than per-snippet, and reuse it across name + description.
    final filteredByCategory = <SnippetCategory, List<TemplateSnippet>>{};
    final q = _searchQuery.toLowerCase();
    for (final entry in snippetsByCategory.entries) {
      if (_searchQuery.isEmpty) {
        filteredByCategory[entry.key] = entry.value;
      } else {
        final filtered = entry.value
            .where((snippet) =>
                snippet.name.toLowerCase().contains(q) ||
                snippet.description.toLowerCase().contains(q))
            .toList();
        if (filtered.isNotEmpty) {
          filteredByCategory[entry.key] = filtered;
        }
      }
    }

    // Order categories in a logical sequence
    final orderedCategories = [
      SnippetCategory.autofocus,
      SnippetCategory.dithering,
      SnippetCategory.filterSequence,
      SnippetCategory.calibration,
      SnippetCategory.safety,
      SnippetCategory.custom,
    ].where((c) => filteredByCategory.containsKey(c)).toList();

    if (widget.isMobileSheet) {
      return _buildMobileSheetContent(filteredByCategory, orderedCategories);
    }

    return _buildDesktopSidebarContent(filteredByCategory, orderedCategories);
  }

  void _update(VoidCallback callback) => setState(callback);
}
