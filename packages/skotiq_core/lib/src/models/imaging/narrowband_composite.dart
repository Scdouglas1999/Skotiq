import 'dart:convert';

/// One persisted narrowband palette composite (Phase C, v44).
///
/// A [NarrowbandComposite] is the `narrowband_composites` row written when a
/// SHO/HOO/etc. palette is applied in the narrowband mixer — the combine of two
/// or more per-filter [IntegratedMaster] channels (e.g. the Ha/OIII/SII masters)
/// into one false-colour FITS. It records which component masters fed the
/// combine, the palette used, the output FITS path, and the composite
/// dimensions, so the composite survives the session and can be surfaced in the
/// review / master library rather than being an orphan file on disk.
class NarrowbandComposite {
  /// DB primary key (`narrowband_composites.id`). Null for an unsaved record.
  final int? id;

  /// DB `targets.id` this composite belongs to, or null.
  final int? targetId;

  /// Palette name (`SHO`, `HOO`, ...).
  final String palette;

  /// The `integrated_masters.id` component channels the composite was built
  /// from, in channel order.
  final List<int> componentMasterIds;

  /// Output composite FITS path.
  final String outputPath;

  final int width;
  final int height;

  /// When the composite row was created (UTC).
  final DateTime createdAt;

  const NarrowbandComposite({
    this.id,
    this.targetId,
    required this.palette,
    required this.componentMasterIds,
    required this.outputPath,
    this.width = 0,
    this.height = 0,
    required this.createdAt,
  });

  /// Encode [componentMasterIds] as the `component_master_ids` JSON column.
  String get componentMasterIdsJson => jsonEncode(componentMasterIds);

  /// Decode a `component_master_ids` JSON column to an `int` list. Tolerant of a
  /// null/blank/garbled column (returns an empty list) so a read never throws.
  static List<int> decodeComponentMasterIds(String? json) {
    if (json == null || json.trim().isEmpty) return const <int>[];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const <int>[];
      return decoded
          .whereType<num>()
          .map((n) => n.toInt())
          .toList(growable: false);
    } catch (_) {
      return const <int>[];
    }
  }

  NarrowbandComposite copyWith({
    int? id,
    int? targetId,
    String? palette,
    List<int>? componentMasterIds,
    String? outputPath,
    int? width,
    int? height,
    DateTime? createdAt,
  }) {
    return NarrowbandComposite(
      id: id ?? this.id,
      targetId: targetId ?? this.targetId,
      palette: palette ?? this.palette,
      componentMasterIds: componentMasterIds ?? this.componentMasterIds,
      outputPath: outputPath ?? this.outputPath,
      width: width ?? this.width,
      height: height ?? this.height,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() =>
      'NarrowbandComposite(palette=$palette, '
      'components=$componentMasterIds, path=$outputPath)';
}
