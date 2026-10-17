import 'dart:convert';

import '../../models/import/canonical_sequence_node.dart';
import '../../models/import/import_result.dart';
import '../../models/sequence/sequence_models.dart';

/// One entry in a Skotiq observing-list JSON document.
class ObservingListEntry {
  final String name;
  final double raHours;
  final double decDegrees;
  final double? rotation;

  /// Higher = more important. Defaults to 0 (= no priority).
  final int priority;

  /// Optional free-form user notes.
  final String? notes;

  /// Optional pre-baked exposure plan. If `null`, the importer emits a
  /// target-only entry that the user will fill in later.
  final List<ObservingListExposure> exposures;

  /// Optional mosaic metadata. When present, the importer attaches a
  /// MosaicPanelInfo to the resulting TargetHeaderNode so other tooling
  /// (target queue, dashboard) groups panels correctly.
  final ObservingListMosaic? mosaic;

  const ObservingListEntry({
    required this.name,
    required this.raHours,
    required this.decDegrees,
    this.rotation,
    this.priority = 0,
    this.notes,
    this.exposures = const [],
    this.mosaic,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'target': <String, dynamic>{
        'name': name,
        'ra': raHours,
        'dec': decDegrees,
        if (rotation != null) 'rotation': rotation,
      },
      'priority': priority,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      if (exposures.isNotEmpty)
        'exposures': exposures.map((e) => e.toJson()).toList(),
      if (mosaic != null) 'mosaic': mosaic!.toJson(),
    };
  }

  factory ObservingListEntry.fromJson(Map<String, dynamic> json) {
    final target = json['target'];
    if (target is! Map) {
      throw MalformedSourceError(
        'Observing list item missing "target" object: $json',
      );
    }
    final raRaw = target['ra'] ?? target['raHours'] ?? target['ra_hours'];
    final decRaw = target['dec'] ?? target['decDegrees'] ?? target['dec_deg'];
    if (raRaw is! num || decRaw is! num) {
      throw MalformedSourceError(
        'Observing list item missing numeric RA/Dec: $target',
      );
    }
    final exposuresRaw = json['exposures'];
    final exposures = <ObservingListExposure>[];
    if (exposuresRaw is List) {
      for (final e in exposuresRaw) {
        if (e is Map<String, dynamic>) {
          exposures.add(ObservingListExposure.fromJson(e));
        }
      }
    }
    final mosaicRaw = json['mosaic'];
    ObservingListMosaic? mosaic;
    if (mosaicRaw is Map<String, dynamic>) {
      mosaic = ObservingListMosaic.fromJson(mosaicRaw);
    }
    return ObservingListEntry(
      name: (target['name'] ?? target['targetName'] ?? '').toString(),
      raHours: (raRaw).toDouble(),
      decDegrees: (decRaw).toDouble(),
      rotation: (target['rotation'] is num)
          ? (target['rotation'] as num).toDouble()
          : null,
      priority: (json['priority'] is num)
          ? (json['priority'] as num).toInt()
          : 0,
      notes: json['notes']?.toString(),
      exposures: exposures,
      mosaic: mosaic,
    );
  }
}

class ObservingListExposure {
  final double durationSecs;
  final int count;
  final String? filter;
  final int? gain;
  final int? offset;

  const ObservingListExposure({
    required this.durationSecs,
    required this.count,
    this.filter,
    this.gain,
    this.offset,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'duration_secs': durationSecs,
    'count': count,
    if (filter != null) 'filter': filter,
    if (gain != null) 'gain': gain,
    if (offset != null) 'offset': offset,
  };

  factory ObservingListExposure.fromJson(Map<String, dynamic> json) {
    return ObservingListExposure(
      durationSecs: (json['duration_secs'] ?? json['durationSecs'] ?? 60)
          .toDouble(),
      count: (json['count'] ?? 1).toInt(),
      filter: json['filter']?.toString(),
      gain: (json['gain'] is num) ? (json['gain'] as num).toInt() : null,
      offset: (json['offset'] is num) ? (json['offset'] as num).toInt() : null,
    );
  }
}

class ObservingListMosaic {
  final String name;
  final int panelIndex;
  final int totalPanels;
  final int row;
  final int column;

  const ObservingListMosaic({
    required this.name,
    required this.panelIndex,
    required this.totalPanels,
    this.row = 0,
    this.column = 0,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'panel_index': panelIndex,
    'total_panels': totalPanels,
    'row': row,
    'column': column,
  };

  factory ObservingListMosaic.fromJson(Map<String, dynamic> json) {
    return ObservingListMosaic(
      name: (json['name'] ?? '').toString(),
      panelIndex: (json['panel_index'] ?? json['panelIndex'] ?? 0).toInt(),
      totalPanels: (json['total_panels'] ?? json['totalPanels'] ?? 1).toInt(),
      row: (json['row'] ?? 0).toInt(),
      column: (json['column'] ?? 0).toInt(),
    );
  }
}

/// Top-level Skotiq observing-list document.
///
/// Round-trippable: [export] takes the user's current items list and produces
/// JSON; [ObservingListJsonImporter.parse] reads that JSON back into a
/// canonical tree the importer pipeline can map. Friends can share the file
/// and end up with identical observing lists on the other end.
class ObservingListDocument {
  /// Version 1 corresponds to the schema described in this file. Bumped if
  /// the on-disk shape changes in incompatible ways.
  static const int schemaVersion = 1;

  final String name;
  final int version;
  final String? description;
  final List<ObservingListEntry> items;
  final DateTime? createdAt;

  const ObservingListDocument({
    required this.name,
    this.version = schemaVersion,
    this.description,
    required this.items,
    this.createdAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'version': version,
    if (description != null) 'description': description,
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
    'items': items.map((i) => i.toJson()).toList(),
  };

  factory ObservingListDocument.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] is num)
        ? (json['version'] as num).toInt()
        : 1;
    if (version < 1 || version > schemaVersion) {
      throw MalformedSourceError(
        'Unsupported observing-list schema version $version '
        '(this build supports v1..v$schemaVersion)',
      );
    }
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw MalformedSourceError(
        'Observing list missing "items" array (got ${rawItems.runtimeType})',
      );
    }
    final items = <ObservingListEntry>[];
    for (final raw in rawItems) {
      if (raw is Map<String, dynamic>) {
        items.add(ObservingListEntry.fromJson(raw));
      } else {
        throw MalformedSourceError(
          'Observing list item is not an object: $raw',
        );
      }
    }
    return ObservingListDocument(
      name: (json['name'] ?? 'Observing List').toString(),
      version: version,
      description: json['description']?.toString(),
      items: items,
      createdAt: (json['created_at'] is String)
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
    );
  }
}

/// Importer for Skotiq-native observing-list JSON.
class ObservingListJsonImporter {
  /// Quick format sniff: leading slice must be a JSON object containing the
  /// observing-list discriminator keys (`items` + `version`, or the
  /// Skotiq `_format: "observing_list_v1"` marker).
  static bool sniff(String content) {
    final trimmed = content.trimLeft();
    if (!trimmed.startsWith('{')) return false;
    // Take a generous slice — most observing-list files have the header in
    // the first ~512 bytes.
    final slice = trimmed.length > 2048 ? trimmed.substring(0, 2048) : trimmed;
    // Explicit format marker wins.
    if (slice.contains('"observing_list_v1"') ||
        slice.contains('"_format"') && slice.contains('observing_list')) {
      return true;
    }
    // Heuristic: schema requires "items" + (at least) one of the canonical
    // markers. NINA files also have "Items" (capital-I) — case matters.
    final hasItems = RegExp(r'"items"\s*:').hasMatch(slice);
    if (!hasItems) return false;
    final hasVersion = RegExp(r'"version"\s*:\s*\d').hasMatch(slice);
    final hasTargetShape = slice.contains('"target"');
    return hasVersion || hasTargetShape;
  }

  /// Parse [content] into a canonical tree. Throws [MalformedSourceError]
  /// for invalid JSON or missing required fields.
  CanonicalSequenceNode parse(String content, {String? sequenceName}) {
    Object? raw;
    try {
      raw = jsonDecode(content);
    } catch (e) {
      throw MalformedSourceError('Observing list is not valid JSON', cause: e);
    }
    if (raw is! Map<String, dynamic>) {
      throw MalformedSourceError(
        'Observing list root must be a JSON object, got ${raw.runtimeType}',
      );
    }
    final doc = ObservingListDocument.fromJson(raw);

    final children = <CanonicalSequenceNode>[];
    // Match the target library and native scheduler: higher numeric priority
    // runs first. Preserve document order for equal priorities.
    final sorted = doc.items.indexed.toList()
      ..sort((a, b) {
        final byPriority = b.$2.priority.compareTo(a.$2.priority);
        if (byPriority != 0) return byPriority;
        return a.$1.compareTo(b.$1);
      });
    for (final (_, item) in sorted) {
      children.add(_buildTargetNode(item));
    }

    return CanonicalSequenceNode(
      kind: CanonicalKind.sequential,
      name: sequenceName ?? doc.name,
      sourceType: 'ObservingListDocument',
      attributes: <String, Object?>{
        'observingListName': doc.name,
        'observingListVersion': doc.version,
        if (doc.description != null) 'description': doc.description,
        'itemCount': doc.items.length,
      },
      children: children,
    );
  }

  CanonicalSequenceNode _buildTargetNode(ObservingListEntry item) {
    final children = <CanonicalSequenceNode>[];
    for (final exposure in item.exposures) {
      children.add(
        CanonicalSequenceNode(
          kind: CanonicalKind.exposure,
          name: 'Light',
          sourceType: 'ObservingListExposure',
          attributes: {
            'exposureTime': exposure.durationSecs,
            'count': exposure.count,
            if (exposure.filter != null) 'filterName': exposure.filter,
            if (exposure.gain != null) 'gain': exposure.gain,
            if (exposure.offset != null) 'offset': exposure.offset,
            'imageType': 'LIGHT',
          },
        ),
      );
    }

    final attrs = <String, Object?>{
      'targetName': item.name,
      'raHours': item.raHours,
      'decDegrees': item.decDegrees,
      if (item.rotation != null) 'rotation': item.rotation,
      if (item.notes != null) 'notes': item.notes,
      'priority': item.priority,
    };
    if (item.mosaic != null) {
      attrs['mosaicName'] = item.mosaic!.name;
      attrs['mosaicPanelIndex'] = item.mosaic!.panelIndex;
      attrs['mosaicTotalPanels'] = item.mosaic!.totalPanels;
      attrs['mosaicRow'] = item.mosaic!.row;
      attrs['mosaicColumn'] = item.mosaic!.column;
    }

    return CanonicalSequenceNode(
      kind: CanonicalKind.targetHeader,
      name: item.name,
      sourceType: 'ObservingListTarget',
      attributes: attrs,
      children: children,
    );
  }

  /// Export a Skotiq [Sequence] to observing-list JSON. The exporter
  /// walks the sequence tree and turns every [TargetHeaderNode] into an
  /// [ObservingListEntry]. Exposure plans defined by direct [ExposureNode]
  /// children are preserved.
  ///
  /// The output is pretty-printed (2-space indent) for human inspection
  /// and diff-friendliness.
  static String export(Sequence sequence, {String? name, String? description}) {
    final items = <ObservingListEntry>[];
    for (final node in sequence.nodes.values) {
      if (node is! TargetHeaderNode) continue;
      final exposures = <ObservingListExposure>[];
      for (final childId in node.childIds) {
        final child = sequence.nodes[childId];
        if (child is ExposureNode) {
          exposures.add(
            ObservingListExposure(
              durationSecs: child.durationSecs,
              count: child.count,
              filter: child.filter,
              gain: child.gain,
              offset: child.offset,
            ),
          );
        }
      }
      items.add(
        ObservingListEntry(
          name: node.targetName,
          raHours: node.raHours,
          decDegrees: node.decDegrees,
          rotation: node.rotation,
          priority: node.priority,
          notes: node.comment,
          exposures: exposures,
          mosaic: node.mosaicPanel == null
              ? null
              : ObservingListMosaic(
                  name: node.mosaicPanel!.mosaicName,
                  panelIndex: node.mosaicPanel!.panelIndex,
                  totalPanels: node.mosaicPanel!.totalPanels,
                  row: node.mosaicPanel!.row,
                  column: node.mosaicPanel!.column,
                ),
        ),
      );
    }
    final doc = ObservingListDocument(
      name: name ?? sequence.name,
      description: description ?? sequence.description,
      items: items,
      createdAt: DateTime.now().toUtc(),
    );
    final payload = <String, dynamic>{
      '_format': 'observing_list_v1',
      ...doc.toJson(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }
}
