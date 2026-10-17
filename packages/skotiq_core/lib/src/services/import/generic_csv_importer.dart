import '../../models/import/canonical_sequence_node.dart';
import '../../models/import/import_result.dart';
import 'csv_parser.dart';
import 'telescopius_csv_importer.dart' show TelescopiusCsvImporter;

/// Column-mapping for a generic CSV. The UI builds one of these from a
/// dropdown dialog before calling the importer.
class CsvColumnMapping {
  /// Column index of the target name.
  final int nameColumn;

  /// Column index of right ascension. Coordinates are parsed using the same
  /// flexible parser the Telescopius importer uses (HMS, DMS, decimal).
  final int raColumn;

  /// Column index of declination.
  final int decColumn;

  /// Optional column index of rotation in degrees.
  final int? rotationColumn;

  /// Optional column index of frame count.
  final int? countColumn;

  /// Optional column index of sub-exposure length in seconds.
  final int? exposureTimeColumn;

  /// Optional column index of filter name.
  final int? filterColumn;

  /// Optional column index of priority (higher = more important).
  final int? priorityColumn;

  /// Optional column index of notes.
  final int? notesColumn;

  /// Skip the first row (assumes it's a header). Defaults to true.
  final bool skipHeader;

  const CsvColumnMapping({
    required this.nameColumn,
    required this.raColumn,
    required this.decColumn,
    this.rotationColumn,
    this.countColumn,
    this.exposureTimeColumn,
    this.filterColumn,
    this.priorityColumn,
    this.notesColumn,
    this.skipHeader = true,
  });

  /// Serialize to JSON for the column-mapping-preset store. Preset keys are
  /// derived from the CSV's header row so future imports with the same shape
  /// auto-apply the mapping.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'name_col': nameColumn,
    'ra_col': raColumn,
    'dec_col': decColumn,
    if (rotationColumn != null) 'rotation_col': rotationColumn,
    if (countColumn != null) 'count_col': countColumn,
    if (exposureTimeColumn != null) 'exposure_col': exposureTimeColumn,
    if (filterColumn != null) 'filter_col': filterColumn,
    if (priorityColumn != null) 'priority_col': priorityColumn,
    if (notesColumn != null) 'notes_col': notesColumn,
    'skip_header': skipHeader,
  };

  factory CsvColumnMapping.fromJson(Map<String, dynamic> json) {
    int? optInt(String key) =>
        (json[key] is num) ? (json[key] as num).toInt() : null;
    return CsvColumnMapping(
      nameColumn: (json['name_col'] as num).toInt(),
      raColumn: (json['ra_col'] as num).toInt(),
      decColumn: (json['dec_col'] as num).toInt(),
      rotationColumn: optInt('rotation_col'),
      countColumn: optInt('count_col'),
      exposureTimeColumn: optInt('exposure_col'),
      filterColumn: optInt('filter_col'),
      priorityColumn: optInt('priority_col'),
      notesColumn: optInt('notes_col'),
      skipHeader: json['skip_header'] != false,
    );
  }
}

/// A preview of a CSV file used to drive the column-mapping dialog. The
/// importer surfaces this when [SequenceImporter] sees a CSV that doesn't
/// match Telescopius or Astrobin.
class CsvPreview {
  /// Column headers (the first row, if [hasHeader] is true).
  final List<String>? headers;

  /// First N data rows (5 by default) for the UI to show alongside the
  /// dropdowns.
  final List<List<String>> sampleRows;

  /// Total number of columns. The mapping dialog enforces dropdowns within
  /// `[0, columnCount)`.
  final int columnCount;

  /// Total number of rows in the file (including header).
  final int totalRows;

  /// A stable key derived from the headers (or first row signature) that
  /// callers can use to look up a saved column-mapping preset.
  final String signatureKey;

  /// True when the first row looks like headers (non-numeric cells).
  final bool hasHeader;

  CsvPreview({
    required this.headers,
    required this.sampleRows,
    required this.columnCount,
    required this.totalRows,
    required this.signatureKey,
    required this.hasHeader,
  });
}

/// Generic-CSV importer driven by an explicit column mapping.
class GenericCsvImporter {
  /// Build a preview from raw CSV content. Used by the import dialog to
  /// populate the column-mapping screen.
  static CsvPreview preview(String content, {int sampleSize = 5}) {
    final rows = CsvParser.parse(content);
    if (rows.isEmpty) {
      throw MalformedSourceError('CSV is empty');
    }
    final columnCount = rows.first.length;
    // A row "looks like a header" if it has no numeric cells. That's a
    // good heuristic for the CSVs astrophotographers actually share.
    final hasHeader = rows.first.every(
      (c) => double.tryParse(c.trim()) == null,
    );
    final headers = hasHeader ? rows.first : null;
    final dataRows = hasHeader ? rows.skip(1).toList() : rows;
    final sample = dataRows.take(sampleSize).toList();
    final signatureKey = _signature(
      hasHeader ? rows.first : <String>['col0', 'col1'],
      columnCount,
    );
    return CsvPreview(
      headers: headers,
      sampleRows: sample,
      columnCount: columnCount,
      totalRows: rows.length,
      signatureKey: signatureKey,
      hasHeader: hasHeader,
    );
  }

  /// Apply [mapping] to [content] and produce a canonical tree.
  CanonicalSequenceNode parse(
    String content, {
    required CsvColumnMapping mapping,
    String? sequenceName,
  }) {
    final rows = CsvParser.parse(content);
    if (rows.isEmpty) {
      throw MalformedSourceError('CSV is empty');
    }
    final dataRows = mapping.skipHeader ? rows.skip(1).toList() : rows;
    if (dataRows.isEmpty) {
      throw MalformedSourceError('CSV has no data rows');
    }

    final children = <CanonicalSequenceNode>[];
    var rowNum = mapping.skipHeader ? 1 : 0;
    for (final row in dataRows) {
      rowNum++;
      String? cell(int idx) {
        if (idx < 0 || idx >= row.length) return null;
        final v = row[idx].trim();
        return v.isEmpty ? null : v;
      }

      final name = cell(mapping.nameColumn);
      final raRaw = cell(mapping.raColumn);
      final decRaw = cell(mapping.decColumn);
      if (name == null || raRaw == null || decRaw == null) {
        throw MalformedSourceError(
          'Generic CSV row $rowNum is missing required name/RA/Dec values',
        );
      }
      final ra = TelescopiusCsvImporter.parseRaToHours(raRaw);
      final dec = TelescopiusCsvImporter.parseDecToDegrees(decRaw);
      if (ra == null || dec == null) {
        throw MalformedSourceError(
          'Generic CSV row $rowNum ($name) has unparseable RA/Dec: '
          'RA="$raRaw" Dec="$decRaw"',
        );
      }

      final rotation = mapping.rotationColumn == null
          ? null
          : double.tryParse(cell(mapping.rotationColumn!) ?? '');
      final exposureTime = mapping.exposureTimeColumn == null
          ? null
          : double.tryParse(cell(mapping.exposureTimeColumn!) ?? '');
      final count = mapping.countColumn == null
          ? null
          : int.tryParse(cell(mapping.countColumn!) ?? '');
      final filter = mapping.filterColumn == null
          ? null
          : cell(mapping.filterColumn!);
      final priority = mapping.priorityColumn == null
          ? null
          : int.tryParse(cell(mapping.priorityColumn!) ?? '');
      final notes = mapping.notesColumn == null
          ? null
          : cell(mapping.notesColumn!);

      final attrs = <String, Object?>{
        'targetName': name,
        'raHours': ra,
        'decDegrees': dec,
        if (rotation != null) 'rotation': rotation,
        if (priority != null) 'priority': priority,
        if (notes != null) 'notes': notes,
      };
      final exposureChildren = <CanonicalSequenceNode>[];
      if (exposureTime != null || count != null) {
        exposureChildren.add(
          CanonicalSequenceNode(
            kind: CanonicalKind.exposure,
            name: 'Light',
            sourceType: 'GenericCsvExposure',
            attributes: {
              'exposureTime': exposureTime ?? 60.0,
              'count': count ?? 1,
              if (filter != null) 'filterName': filter,
              'imageType': 'LIGHT',
            },
          ),
        );
      }

      children.add(
        CanonicalSequenceNode(
          kind: CanonicalKind.targetHeader,
          name: name,
          sourceType: 'GenericCsvTarget',
          attributes: attrs,
          children: exposureChildren,
        ),
      );
    }

    return CanonicalSequenceNode(
      kind: CanonicalKind.sequential,
      name: sequenceName ?? 'CSV Import',
      sourceType: 'GenericCsv',
      attributes: {'rowCount': dataRows.length},
      children: children,
    );
  }

  /// Sniff: any text that parses as CSV and has at least 2 columns. We use
  /// this as the last-resort detector in the [SequenceImporter] pipeline so
  /// the importer can fall back to the column-mapping dialog rather than
  /// throwing [UnknownFormatError] outright.
  static bool sniff(String content) {
    if (content.isEmpty) return false;
    final firstLine = _firstNonEmptyLine(content);
    if (firstLine == null) return false;
    if (!firstLine.contains(',')) return false;
    // Avoid masquerading as JSON.
    if (firstLine.trimLeft().startsWith('{') ||
        firstLine.trimLeft().startsWith('[')) {
      return false;
    }
    return true;
  }

  static String _signature(List<String> headerOrRow, int columnCount) {
    final normalized = headerOrRow
        .map((c) => c.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_'))
        .join('|');
    return '$columnCount:$normalized';
  }

  static String? _firstNonEmptyLine(String content) {
    for (final line in content.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }
}
