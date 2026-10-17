import '../../models/import/canonical_sequence_node.dart';
import '../../models/import/import_result.dart';
import '../../utils/coordinate_parser.dart';
import 'csv_parser.dart';

/// Parses Telescopius target / mosaic CSV exports into a [CanonicalSequenceNode]
/// tree.
///
/// Telescopius is the de facto standard for sharing imaging-target lists and
/// mosaic plans in the astrophotography community. Their export schema is:
///
/// ```
/// "Pane","Designation","Right Ascension","Declination","Rotation","Magnitude",
/// "Constellation","Object Type","Size","Distance","Visual Description",
/// "Imaging Description"
/// "1","M42","05h35m17.3s","-05°23'28\"","37.5","4.0","Orion","Diffuse Nebula",
/// "85x60","1344","..","..."
/// ```
///
/// Key parsing rules:
/// * **RA** parsed as `HHhMMmSS.SsZZ` → decimal hours.
/// * **Dec** parsed as `±DD°MM'SS.S"` → decimal degrees (handles UTF-8 and
///   ASCII degree/minute/second separators).
/// * **Pane** (optional column) — when present and `>1`, signals a multi-panel
///   mosaic. Rows with the same Designation are grouped under a parent
///   sequential container; each row becomes a TargetHeaderNode with
///   [MosaicPanelInfo].
/// * **Rotation** is per-row (per-panel) and applied verbatim to
///   `TargetHeaderNode.rotation`.
/// * The schema is robust to Telescopius adding/removing columns over time:
///   we identify columns by their header name, not their positional index.
/// * Extension columns (`Sub Length`, `Count`, `Filter`) are honored when
///   present and produce an in-line ExposureNode child of the target.
class TelescopiusCsvImporter {
  /// Quick format sniff: does the leading slice of [content] look like a
  /// Telescopius CSV? Telescopius headers are quoted and always include
  /// `Designation`, `Right Ascension`, and `Declination`.
  static bool sniff(String content) {
    if (content.isEmpty) return false;
    final firstLine = _firstNonEmptyLine(content);
    if (firstLine == null) return false;
    final lower = firstLine.toLowerCase();
    // Required column set for a confident Telescopius identification.
    final hasDesignation =
        lower.contains('"designation"') ||
        lower.contains(',designation,') ||
        lower.startsWith('designation,');
    final hasRa =
        lower.contains('"right ascension"') ||
        lower.contains(',right ascension,') ||
        lower.startsWith('right ascension,');
    final hasDec =
        lower.contains('"declination"') ||
        lower.contains(',declination,') ||
        lower.startsWith('declination,');
    return hasDesignation && hasRa && hasDec;
  }

  /// Parse [content] into a canonical tree.
  ///
  /// Throws [MalformedSourceError] if the file isn't valid CSV or required
  /// columns are missing.
  CanonicalSequenceNode parse(String content, {String? sequenceName}) {
    final rows = CsvParser.parse(content);
    if (rows.isEmpty) {
      throw MalformedSourceError('Telescopius CSV is empty');
    }

    // The first non-empty row is the header.
    final header = rows.first
        .map((c) => _normalizeHeader(c))
        .toList(growable: false);
    final dataRows = rows.skip(1).where((r) => _hasContent(r)).toList();

    // Identify column indices by name (Telescopius adds new columns over time,
    // so positional lookup would be fragile).
    final idxDesignation = _findColumn(header, [
      'designation',
      'name',
      'target',
    ]);
    final idxRa = _findColumn(header, ['rightascension', 'ra']);
    final idxDec = _findColumn(header, ['declination', 'dec']);
    if (idxDesignation < 0 || idxRa < 0 || idxDec < 0) {
      throw MalformedSourceError(
        'Telescopius CSV missing required columns (need Designation, '
        'Right Ascension, Declination). Got: ${header.join(", ")}',
      );
    }
    final idxPane = _findColumn(header, ['pane', 'panel', 'panelindex']);
    final idxRotation = _findColumn(header, [
      'rotation',
      'positionangle',
      'pa',
    ]);
    final idxMagnitude = _findColumn(header, ['magnitude', 'mag']);
    final idxConstellation = _findColumn(header, ['constellation']);
    final idxObjectType = _findColumn(header, ['objecttype', 'type']);
    final idxSize = _findColumn(header, ['size']);
    final idxDistance = _findColumn(header, ['distance']);
    final idxVisualDesc = _findColumn(header, ['visualdescription']);
    final idxImagingDesc = _findColumn(header, [
      'imagingdescription',
      'description',
    ]);
    // Optional extension columns Telescopius (and the community) sometimes
    // append.
    final idxSubLength = _findColumn(header, [
      'sublength',
      'subexposure',
      'exposuretime',
    ]);
    final idxCount = _findColumn(header, ['count', 'subs', 'frames']);
    final idxFilter = _findColumn(header, ['filter']);

    // Unknown columns we still preserve in attributes for round-trip / UI.
    final unknownColumns = <int, String>{};
    for (var i = 0; i < header.length; i++) {
      if (i == idxDesignation ||
          i == idxRa ||
          i == idxDec ||
          i == idxPane ||
          i == idxRotation ||
          i == idxMagnitude ||
          i == idxConstellation ||
          i == idxObjectType ||
          i == idxSize ||
          i == idxDistance ||
          i == idxVisualDesc ||
          i == idxImagingDesc ||
          i == idxSubLength ||
          i == idxCount ||
          i == idxFilter) {
        continue;
      }
      unknownColumns[i] = header[i];
    }

    // Group rows by Designation so we can recognize mosaic panes (multiple
    // rows with the same Designation = panes of one mosaic).
    final rowsByDesignation = <String, List<_ParsedRow>>{};
    final ordering = <String>[];
    var rowNum = 1; // header is row 0
    for (final row in dataRows) {
      rowNum++;
      final parsed = _parseRow(
        row: row,
        rowNum: rowNum,
        idxDesignation: idxDesignation,
        idxRa: idxRa,
        idxDec: idxDec,
        idxPane: idxPane,
        idxRotation: idxRotation,
        idxMagnitude: idxMagnitude,
        idxConstellation: idxConstellation,
        idxObjectType: idxObjectType,
        idxSize: idxSize,
        idxDistance: idxDistance,
        idxVisualDesc: idxVisualDesc,
        idxImagingDesc: idxImagingDesc,
        idxSubLength: idxSubLength,
        idxCount: idxCount,
        idxFilter: idxFilter,
        unknownColumns: unknownColumns,
      );
      if (parsed == null) continue;
      if (!rowsByDesignation.containsKey(parsed.designation)) {
        ordering.add(parsed.designation);
      }
      rowsByDesignation.putIfAbsent(parsed.designation, () => []).add(parsed);
    }

    if (rowsByDesignation.isEmpty) {
      throw MalformedSourceError(
        'Telescopius CSV has no parseable target rows '
        '(found ${dataRows.length} data rows, none had valid RA/Dec)',
      );
    }

    // Build canonical children: one TargetHeaderNode per single-row group,
    // one sequential container (mosaic group) per multi-row group.
    final children = <CanonicalSequenceNode>[];
    for (final designation in ordering) {
      final group = rowsByDesignation[designation]!;
      if (group.length == 1 && !group.first.isMosaicPane) {
        children.add(_buildSingleTarget(group.first));
      } else {
        children.add(_buildMosaicGroup(designation, group));
      }
    }

    final rootName = sequenceName ?? 'Telescopius Import';
    return CanonicalSequenceNode(
      kind: CanonicalKind.sequential,
      name: rootName,
      sourceType: 'TelescopiusCsv',
      attributes: {
        'totalTargets': rowsByDesignation.length,
        'totalRows': dataRows.length,
      },
      children: children,
    );
  }

  CanonicalSequenceNode _buildSingleTarget(_ParsedRow row) {
    final children = <CanonicalSequenceNode>[];
    final exposure = _buildExposureIfPresent(row);
    if (exposure != null) children.add(exposure);

    return CanonicalSequenceNode(
      kind: CanonicalKind.targetHeader,
      name: row.designation,
      sourceType: 'TelescopiusTarget',
      attributes: {
        'targetName': row.designation,
        'raHours': row.raHours,
        'decDegrees': row.decDegrees,
        if (row.rotation != null) 'rotation': row.rotation,
        ..._metaAttributes(row),
      },
      children: children,
    );
  }

  CanonicalSequenceNode _buildMosaicGroup(
    String designation,
    List<_ParsedRow> group,
  ) {
    // Sort panes by their pane number (1-indexed in Telescopius).
    final sorted = [...group]
      ..sort((a, b) => (a.paneIndex ?? 0).compareTo(b.paneIndex ?? 0));
    final total = sorted.length;

    final panels = <CanonicalSequenceNode>[];
    for (var i = 0; i < sorted.length; i++) {
      final row = sorted[i];
      // Telescopius pane indices are 1-based; we expose 0-based to the model
      // (consistent with MosaicPanelInfo.panelIndex which is 0-based).
      final panelIndex = (row.paneIndex != null && row.paneIndex! > 0)
          ? row.paneIndex! - 1
          : i;
      final children = <CanonicalSequenceNode>[];
      final exposure = _buildExposureIfPresent(row);
      if (exposure != null) children.add(exposure);

      panels.add(
        CanonicalSequenceNode(
          kind: CanonicalKind.targetHeader,
          name: '$designation (Panel ${panelIndex + 1}/$total)',
          sourceType: 'TelescopiusMosaicPanel',
          attributes: {
            'targetName': designation,
            'raHours': row.raHours,
            'decDegrees': row.decDegrees,
            if (row.rotation != null) 'rotation': row.rotation,
            'mosaicName': designation,
            'mosaicPanelIndex': panelIndex,
            'mosaicTotalPanels': total,
            // Row/column unknown from CSV alone; we keep a flat layout
            // (column = index, row = 0). MosaicService can re-grid them later.
            'mosaicRow': 0,
            'mosaicColumn': panelIndex,
            ..._metaAttributes(row),
          },
          children: children,
        ),
      );
    }

    // Wrap panels in a sequential container so they show up as a coherent
    // group in the imported sequence tree.
    return CanonicalSequenceNode(
      kind: CanonicalKind.sequential,
      name: '$designation Mosaic ($total panels)',
      sourceType: 'TelescopiusMosaicGroup',
      attributes: {
        'mosaicName': designation,
        'panelCount': total,
        'isMosaicGroup': true,
      },
      children: panels,
    );
  }

  CanonicalSequenceNode? _buildExposureIfPresent(_ParsedRow row) {
    final subLength = row.subLengthSecs;
    final count = row.count;
    if (subLength == null && count == null) return null;
    return CanonicalSequenceNode(
      kind: CanonicalKind.exposure,
      name: 'Light',
      sourceType: 'TelescopiusExposure',
      attributes: {
        'exposureTime': subLength ?? 60.0,
        'count': count ?? 1,
        if (row.filter != null) 'filterName': row.filter,
        'imageType': 'LIGHT',
      },
    );
  }

  Map<String, Object?> _metaAttributes(_ParsedRow row) {
    return <String, Object?>{
      if (row.magnitude != null) 'magnitude': row.magnitude,
      if (row.constellation != null) 'constellation': row.constellation,
      if (row.objectType != null) 'objectType': row.objectType,
      if (row.size != null) 'size': row.size,
      if (row.distance != null) 'distance': row.distance,
      if (row.visualDescription != null)
        'visualDescription': row.visualDescription,
      if (row.imagingDescription != null)
        'imagingDescription': row.imagingDescription,
      if (row.unknown.isNotEmpty) 'unknownColumns': row.unknown,
    };
  }

  _ParsedRow? _parseRow({
    required List<String> row,
    required int rowNum,
    required int idxDesignation,
    required int idxRa,
    required int idxDec,
    required int idxPane,
    required int idxRotation,
    required int idxMagnitude,
    required int idxConstellation,
    required int idxObjectType,
    required int idxSize,
    required int idxDistance,
    required int idxVisualDesc,
    required int idxImagingDesc,
    required int idxSubLength,
    required int idxCount,
    required int idxFilter,
    required Map<int, String> unknownColumns,
  }) {
    String? cell(int idx) {
      if (idx < 0 || idx >= row.length) return null;
      final v = row[idx].trim();
      return v.isEmpty ? null : v;
    }

    final designation = cell(idxDesignation);
    if (designation == null) return null;

    final raText = cell(idxRa);
    final decText = cell(idxDec);
    if (raText == null || decText == null) {
      throw MalformedSourceError(
        'Telescopius CSV row $rowNum ($designation) is missing RA or Dec',
      );
    }

    final ra = parseRaToHours(raText);
    final dec = parseDecToDegrees(decText);
    if (ra == null || dec == null) {
      throw MalformedSourceError(
        'Telescopius CSV row $rowNum ($designation) has unparseable '
        'coordinates: RA="$raText" Dec="$decText"',
      );
    }

    final paneText = cell(idxPane);
    final paneIndex = paneText == null ? null : int.tryParse(paneText);
    final rotation = _parseDouble(cell(idxRotation));
    final magnitude = _parseDouble(cell(idxMagnitude));

    final unknown = <String, Object?>{};
    unknownColumns.forEach((idx, name) {
      final v = cell(idx);
      if (v != null) unknown[name] = v;
    });

    return _ParsedRow(
      designation: designation,
      raHours: ra,
      decDegrees: dec,
      paneIndex: paneIndex,
      rotation: rotation,
      magnitude: magnitude,
      constellation: cell(idxConstellation),
      objectType: cell(idxObjectType),
      size: cell(idxSize),
      distance: cell(idxDistance),
      visualDescription: cell(idxVisualDesc),
      imagingDescription: cell(idxImagingDesc),
      subLengthSecs: _parseDouble(cell(idxSubLength)),
      count: _parseInt(cell(idxCount)),
      filter: cell(idxFilter),
      unknown: unknown,
    );
  }

  /// Parse a Telescopius RA string into decimal hours.
  ///
  /// Accepts the canonical Telescopius format `HHhMMmSS.SsZZ` (UTC-suffixed)
  /// as well as decimal hours, `HH:MM:SS.S`, and `HH MM SS.S`.
  static double? parseRaToHours(String raw) {
    final text = raw
        .trim()
        .replaceFirst(RegExp(r'(?:z|utc)+$', caseSensitive: false), '')
        .trim();
    if (text.isEmpty) return null;
    // Plain decimal hours.
    final decimal = double.tryParse(text);
    if (decimal != null && !text.contains(RegExp(r'[hHmMsS:]'))) {
      return decimal.isFinite && decimal >= 0 && decimal < 24 ? decimal : null;
    }
    return CoordinateParser.parseRa(text);
  }

  /// Parse a Telescopius Dec string into decimal degrees.
  ///
  /// Accepts `±DD°MM'SS.S"`, `±DD MM SS.S`, `±DD:MM:SS.S`, and decimal
  /// degrees. The degree symbol can be Unicode (°) or ASCII (`d`).
  static double? parseDecToDegrees(String raw) {
    final text = raw
        .trim()
        .replaceAll('′', "'")
        .replaceAll('″', '"')
        .replaceAll('”', '"');
    if (text.isEmpty) return null;
    // Plain decimal degrees.
    final decimal = double.tryParse(text);
    if (decimal != null && !text.contains(RegExp(r'''[°dDmM':\s"]'''))) {
      return decimal.isFinite && decimal >= -90 && decimal <= 90
          ? decimal
          : null;
    }
    return CoordinateParser.parseDec(text);
  }

  static int _findColumn(List<String> header, List<String> aliases) {
    for (final alias in aliases) {
      for (var i = 0; i < header.length; i++) {
        if (header[i] == alias) return i;
      }
    }
    return -1;
  }

  static String _normalizeHeader(String raw) {
    return raw.trim().toLowerCase().replaceAll(RegExp(r'[\s_]'), '');
  }

  static double? _parseDouble(String? raw) {
    if (raw == null) return null;
    return double.tryParse(raw.trim());
  }

  static int? _parseInt(String? raw) {
    if (raw == null) return null;
    final n = num.tryParse(raw.trim());
    return n?.toInt();
  }

  static bool _hasContent(List<String> row) {
    return row.any((c) => c.trim().isNotEmpty);
  }

  static String? _firstNonEmptyLine(String content) {
    for (final line in content.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }
}

/// One row from the Telescopius CSV, normalized.
class _ParsedRow {
  final String designation;
  final double raHours;
  final double decDegrees;
  final int? paneIndex;
  final double? rotation;
  final double? magnitude;
  final String? constellation;
  final String? objectType;
  final String? size;
  final String? distance;
  final String? visualDescription;
  final String? imagingDescription;
  final double? subLengthSecs;
  final int? count;
  final String? filter;
  final Map<String, Object?> unknown;

  _ParsedRow({
    required this.designation,
    required this.raHours,
    required this.decDegrees,
    required this.paneIndex,
    required this.rotation,
    required this.magnitude,
    required this.constellation,
    required this.objectType,
    required this.size,
    required this.distance,
    required this.visualDescription,
    required this.imagingDescription,
    required this.subLengthSecs,
    required this.count,
    required this.filter,
    required this.unknown,
  });

  bool get isMosaicPane => paneIndex != null && paneIndex! > 0;
}
