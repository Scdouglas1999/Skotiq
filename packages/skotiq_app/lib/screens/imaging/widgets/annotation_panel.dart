import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:path/path.dart' as p;
import '../../../utils/exported_file_reveal.dart';
import 'annotation_overlay.dart';
import '../../settings/catalog_settings_screen.dart';
import '../imaging_science_state.dart';
import 'annotation_filters.dart';
import 'annotation_reannotate_banner.dart';
import 'annotation_search.dart';
import 'annotation_status_colors.dart';
import 'annotation_quick_settings.dart';
import 'annotation_object_list.dart';
import 'imaging_side_panel.dart';
import '../../../utils/snackbar_helper.dart';

part 'annotation_panel_parts/status_widgets.dart';
part 'annotation_panel_parts/objects_panel.dart';
part 'annotation_panel_parts/tab_panel.dart';
part 'annotation_panel_parts/mini_chips.dart';
part 'annotation_panel_parts/preset_name_dialog.dart';
part 'annotation_panel_parts/export_menu.dart';

final annotationPanelVisibleProvider = StateProvider<bool>((ref) => false);

enum AnnotationPanelSortMode { brightness, name, type }

final annotationPanelSortModeProvider =
    StateProvider<AnnotationPanelSortMode>((ref) {
  return AnnotationPanelSortMode.brightness;
});

ShapeBorder _annotationMenuShape(SkotiqColors colors) {
  return RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
    side: BorderSide(color: colors.border),
  );
}

Widget _annotationAuthorityState({
  required SkotiqColors colors,
  required String label,
  required VoidCallback onRetry,
  Object? error,
}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error == null)
            const SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)
          else
            Icon(SkotiqIcons.warning, color: colors.error, size: 20),
          const SizedBox(height: 10),
          Text(
            error == null ? 'Loading $label…' : 'Could not load $label',
            textAlign: TextAlign.center,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textPrimary,
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(
              userFacingError(error),
              textAlign: TextAlign.center,
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: 10),
            SkotiqButton(
              label: 'Retry annotation settings',
              icon: SkotiqIcons.refresh,
              variant: ButtonVariant.outline,
              size: ButtonSize.small,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    ),
  );
}

/// Banner shown when annotation catalog is not installed
