import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;
import '../../../utils/exported_file_reveal.dart';
import '../../../widgets/annotation_overlay.dart';
import '../../settings/catalog_settings_screen.dart';
import '../imaging_screen.dart' show annotationCatalogInstalledProvider;
import '../imaging_science_state.dart';
import 'annotation_filters.dart';
import 'annotation_reannotate_banner.dart';
import 'annotation_search.dart';
import 'annotation_quick_settings.dart';
import 'annotation_object_list.dart';
import 'imaging_side_panel.dart';

part 'annotation_panel_parts/status_widgets.dart';
part 'annotation_panel_parts/objects_panel.dart';
part 'annotation_panel_parts/tab_panel.dart';
part 'annotation_panel_parts/mini_chips.dart';
part 'annotation_panel_parts/preset_name_dialog.dart';

// Export helpers

String _objectTypeName(ObjectType type) {
  switch (type) {
    case ObjectType.galaxy:
      return 'Galaxy';
    case ObjectType.nebula:
      return 'Nebula';
    case ObjectType.starCluster:
      return 'Star Cluster';
    case ObjectType.planetaryNebula:
      return 'Planetary Nebula';
    case ObjectType.star:
      return 'Star';
    case ObjectType.doubleStar:
      return 'Double Star';
    case ObjectType.asterism:
      return 'Asterism';
    case ObjectType.unknown:
      return 'Unknown';
  }
}

/// Generate CSV content from a list of annotated objects.
/// Columns: name, catalogId, type, ra_hours, dec_degrees, magnitude, size_arcmin
String generateAnnotationCsv(List<CelestialObjectAnnotation> objects) {
  final buf = StringBuffer();
  buf.writeln('name,catalogId,type,ra_hours,dec_degrees,magnitude,size_arcmin');
  for (final obj in objects) {
    final name = _csvEscape(obj.commonName ?? obj.name);
    final catalogId = _csvEscape(obj.catalogId ?? '');
    final type = _csvEscape(_objectTypeName(obj.type));
    // RA is stored in degrees; convert to hours (degrees / 15)
    final raHours = (obj.ra / 15.0).toStringAsFixed(8);
    final dec = obj.dec.toStringAsFixed(6);
    final mag = obj.magnitude?.toStringAsFixed(2) ?? '';
    final size = obj.size?.toStringAsFixed(2) ?? '';
    buf.writeln('$name,$catalogId,$type,$raHours,$dec,$mag,$size');
  }
  return buf.toString();
}

String _csvEscape(String value) {
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// Generate a DS9 region file (FK5) from a list of annotated objects.
String generateDs9RegionFile(List<CelestialObjectAnnotation> objects) {
  final buf = StringBuffer();
  buf.writeln('# Region file format: DS9 version 4.1');
  buf.writeln('global color=green dashlist=8 3 width=1');
  buf.writeln('fk5');
  for (final obj in objects) {
    // RA stored in degrees — DS9 FK5 uses degrees for RA and Dec
    final raDeg = obj.ra.toStringAsFixed(4);
    final decDeg = obj.dec.toStringAsFixed(4);
    // Radius: use object size if available, otherwise default to 1 arcmin
    final radiusArcmin =
        obj.size != null && obj.size! > 0 ? obj.size! / 2.0 : 1.0;
    final radiusStr = "${radiusArcmin.toStringAsFixed(1)}'";
    final label = obj.commonName ?? obj.name;
    buf.writeln('circle($raDeg,$decDeg,$radiusStr) # text={$label}');
  }
  return buf.toString();
}

/// Resolve an export destination and write [content] to it.
///
/// Goes through [chooseExportTarget] rather than `getSaveLocation` because
/// `file_selector` has no save dialog on Android/iOS (`getSavePath` throws
/// UnimplementedError), which made both annotation exports dead on a phone. On
/// touch platforms the file lands in the app sandbox, so callers must hand the
/// returned path to [revealExportedFile].
///
/// Returns the saved path, or null if the user cancelled the desktop dialog.
Future<String?> _saveExportFile({
  required String suggestedName,
  required String content,
  required String label,
  required List<String> extensions,
}) async {
  final target = await chooseExportTarget(
    suggestedName: suggestedName,
    acceptedTypeGroups: [
      XTypeGroup(label: label, extensions: extensions),
    ],
  );
  if (target == null) return null;

  final file = File(target.path);
  await file.writeAsString(content);
  return target.path;
}

/// Provider for the annotation sidebar panel visibility state
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
            const CircularProgressIndicator(strokeWidth: 2)
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
              error.toString(),
              textAlign: TextAlign.center,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
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
