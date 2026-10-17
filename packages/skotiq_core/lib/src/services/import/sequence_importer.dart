import 'dart:io';

import '../../models/import/canonical_sequence_node.dart';
import '../../models/import/import_result.dart';
import '../../models/sequence/sequence_models.dart';
import '../../providers/sequence/sequence_validation.dart';
import 'astrobin_importer.dart';
import 'canonical_node_mapper.dart';
import 'generic_csv_importer.dart';
import 'ics_calendar_importer.dart';
import 'nina_sequence_parser.dart';
import 'observing_list_json_importer.dart';
import 'sgp_sequence_parser.dart';
import 'telescopius_csv_importer.dart';

/// Top-level entry point for importing a sequence / target list file.
///
/// Auto-detects the format from the file contents and routes to the
/// appropriate parser. Supported formats:
///
///   * NINA `.json` sequence exports
///   * Sequence Generator Pro `.sgf` exports
///   * Telescopius `.csv` target / mosaic exports (the most common
///     target-import path in the community)
///   * Skotiq-native observing-list `.json`
///   * Astrobin per-user `.csv` dumps (with optional catalog lookup)
///   * iCalendar `.ics` files with VEVENT entries that carry RA/Dec
///
/// All formats are normalized to a [CanonicalSequenceNode] tree which is
/// then mapped to a Skotiq [Sequence]. Errors propagate as typed
/// exceptions:
///
///   * [UnknownFormatError] — couldn't sniff any supported format.
///     For CSVs with no recognized schema, [tryPreviewGenericCsv] returns
///     a [CsvPreview] the UI can use to drive the column-mapping dialog.
///   * [MalformedSourceError] — file looked like one of the formats but
///     parsing failed.
///   * [UnsupportedNodeError] — strict mode found nodes with no Skotiq
///     equivalent. Caller can retry with `forceUnsupported: true`.
///   * [SequenceImportValidationFailedException] — after a successful
///     parse + map, the unified validator surfaced ERROR-severity issues.
///     Caller can retry with `forceImport: true`.
class SequenceImporter {
  final NinaSequenceParser _nina;
  final SgpSequenceParser _sgp;
  final TelescopiusCsvImporter _telescopius;
  final ObservingListJsonImporter _observingList;
  final IcsCalendarImporter _ics;
  final GenericCsvImporter _genericCsv;
  final AstrobinImporter _astrobin;
  final CanonicalNodeMapper _mapper;

  /// Strategy used by [_runValidation]. Defaults to the pure top-level
  /// [validateSequence] (structural rules only — no Ref required since
  /// the importer runs in a non-Riverpod context). Tests can inject a
  /// fake to assert error paths without depending on the full rule
  /// registry.
  final List<ValidationIssue> Function(Sequence) _validate;

  SequenceImporter({
    NinaSequenceParser? nina,
    SgpSequenceParser? sgp,
    TelescopiusCsvImporter? telescopius,
    ObservingListJsonImporter? observingList,
    IcsCalendarImporter? ics,
    GenericCsvImporter? genericCsv,
    AstrobinImporter? astrobin,
    CanonicalNodeMapper? mapper,
    List<ValidationIssue> Function(Sequence)? validateSequenceFn,
  }) : _nina = nina ?? NinaSequenceParser(),
       _sgp = sgp ?? SgpSequenceParser(),
       _telescopius = telescopius ?? TelescopiusCsvImporter(),
       _observingList = observingList ?? ObservingListJsonImporter(),
       _ics = ics ?? IcsCalendarImporter(),
       _genericCsv = genericCsv ?? GenericCsvImporter(),
       _astrobin = astrobin ?? AstrobinImporter(),
       _mapper = mapper ?? CanonicalNodeMapper(),
       _validate = validateSequenceFn ?? validateSequence;

  /// Detect the format from [content]. Inspects only the first ~16 KB.
  ///
  /// Detection order is most-specific first:
  ///   1. NINA — looks for `NINA.Sequencer.` discriminators.
  ///   2. SGP — looks for `TargetSet` / `SequenceTitle`.
  ///   3. Telescopius CSV — header contains `Designation` / `Right
  ///      Ascension` / `Declination`.
  ///   4. Astrobin CSV — header contains `Subject` / `Integration`.
  ///   5. Observing-list JSON — `_format: "observing_list_v1"` or
  ///      `items: [...]` with a top-level `version`.
  ///   6. ICS — leading `BEGIN:VCALENDAR`.
  ///   7. Generic CSV — any text that looks like CSV. The caller should
  ///      call [tryPreviewGenericCsv] to surface a column-mapping dialog.
  ///
  /// Throws [UnknownFormatError] if no detector matched.
  SourceFormat detectFormat(String content) {
    final snippet = content.length > 16 * 1024
        ? content.substring(0, 16 * 1024)
        : content;
    if (NinaSequenceParser.sniff(snippet)) return SourceFormat.nina;
    if (SgpSequenceParser.sniff(snippet)) return SourceFormat.sgp;
    if (TelescopiusCsvImporter.sniff(snippet)) {
      return SourceFormat.telescopiusCsv;
    }
    if (AstrobinImporter.sniff(snippet)) return SourceFormat.astrobinCsv;
    if (ObservingListJsonImporter.sniff(snippet)) {
      return SourceFormat.observingListJson;
    }
    if (IcsCalendarImporter.sniff(snippet)) return SourceFormat.icsCalendar;
    if (GenericCsvImporter.sniff(snippet)) return SourceFormat.genericCsv;
    throw UnknownFormatError(
      _unknownFormatMessage(snippet),
      sniffedSnippet: snippet.length > 200
          ? snippet.substring(0, 200)
          : snippet,
    );
  }

  /// Build a format-specific "couldn't identify" message. When the
  /// content looks like JSON we steer the user toward the two JSON shapes
  /// we accept (NINA exports / Skotiq observing lists) rather than
  /// emitting the generic "supported formats" list, which is unhelpful
  /// for a `.json` file that simply has the wrong schema.
  String _unknownFormatMessage(String snippet) {
    final trimmed = snippet.trimLeft();
    final looksLikeJson = trimmed.startsWith('{') || trimmed.startsWith('[');
    if (looksLikeJson) {
      return 'This looks like JSON but matched no supported sequence shape. '
          'NINA exports contain a "\$type" key starting with '
          '"NINA.Sequencer..."; Skotiq observing lists contain '
          '"_format": "observing_list_v1". Check that the file is a NINA '
          'sequence export or a Skotiq observing list.';
    }
    return 'Could not identify file format. Supported: NINA (.json), '
        'Sequence Generator Pro (.sgf), Telescopius (.csv), Astrobin (.csv), '
        'Skotiq observing list (.json), iCalendar (.ics).';
  }

  /// Try to detect the format. Returns `null` instead of throwing — used
  /// by the import dialog to decide whether to show the generic-CSV
  /// column-mapping screen.
  SourceFormat? detectFormatOrNull(String content) {
    try {
      return detectFormat(content);
    } on UnknownFormatError {
      return null;
    }
  }

  /// When the importer sees a CSV it can't classify (no Telescopius /
  /// Astrobin signature) it returns [SourceFormat.genericCsv]. This helper
  /// produces a [CsvPreview] for the column-mapping dialog.
  CsvPreview previewGenericCsv(String content) {
    return GenericCsvImporter.preview(content);
  }

  /// Import a file directly from disk.
  Future<ImportResult> importFromPath(
    String filePath, {
    required bool forceUnsupported,
    bool forceImport = false,
    String? sequenceName,
    CsvColumnMapping? csvColumnMapping,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw MalformedSourceError('File does not exist: $filePath');
    }
    final content = await file.readAsString();
    final defaultName = sequenceName ?? _deriveSequenceName(filePath);
    return importFromString(
      content,
      forceUnsupported: forceUnsupported,
      forceImport: forceImport,
      sequenceName: defaultName,
      csvColumnMapping: csvColumnMapping,
    );
  }

  /// Import from raw string content. [sequenceName] becomes the name on the
  /// resulting Skotiq sequence.
  ///
  /// After parse + map, the resulting [Sequence] is run through the
  /// unified validator (`validateSequence` — structural rules). If the
  /// result has ERROR-severity issues and [forceImport] is `false`, a
  /// [SequenceImportValidationFailedException] is thrown carrying both
  /// the issue list and the assembled (but unvalidated) result. The UI
  /// can show the issues and re-invoke with `forceImport: true` if the
  /// user opts to import anyway.
  ///
  /// Warnings and info-level issues never block import — they're
  /// returned via [ImportResult.validationIssues] for display in the
  /// summary dialog.
  ///
  /// For generic CSVs, pass [csvColumnMapping] from the column-mapping
  /// dialog. Calling with no mapping on a generic-CSV file throws
  /// [MalformedSourceError].
  ImportResult importFromString(
    String content, {
    required bool forceUnsupported,
    bool forceImport = false,
    required String sequenceName,
    CsvColumnMapping? csvColumnMapping,
  }) {
    final format = detectFormat(content);
    final CanonicalSequenceNode root;
    switch (format) {
      case SourceFormat.nina:
        root = _nina.parse(content);
        break;
      case SourceFormat.sgp:
        root = _sgp.parse(content);
        break;
      case SourceFormat.telescopiusCsv:
        root = _telescopius.parse(content, sequenceName: sequenceName);
        break;
      case SourceFormat.observingListJson:
        root = _observingList.parse(content, sequenceName: sequenceName);
        break;
      case SourceFormat.icsCalendar:
        root = _ics.parse(content, sequenceName: sequenceName).root;
        break;
      case SourceFormat.astrobinCsv:
        throw MalformedSourceError(
          'Astrobin import requires catalog lookup; use importAstrobinAsync()',
        );
      case SourceFormat.genericCsv:
        if (csvColumnMapping == null) {
          throw MalformedSourceError(
            'Generic CSV requires an explicit column mapping. Use '
            'previewGenericCsv() and present a column-mapping dialog '
            'before calling importFromString().',
          );
        }
        root = _genericCsv.parse(
          content,
          mapping: csvColumnMapping,
          sequenceName: sequenceName,
        );
        break;
    }
    return _mapAndAssemble(
      root,
      format,
      sequenceName,
      forceUnsupported,
      forceImport,
    );
  }

  /// Async variant for Astrobin imports, which need to resolve designations
  /// against a catalog before producing target rows.
  ///
  /// The returned [AstrobinImportResult] carries the [ImportResult] plus
  /// the list of unresolved designations so the UI can show "12 targets
  /// resolved, 3 needed manual coordinates".
  Future<AstrobinImportResult> importAstrobinAsync(
    String content, {
    required bool forceUnsupported,
    bool forceImport = false,
    required String sequenceName,
  }) async {
    final summary = await _astrobin.parse(content, sequenceName: sequenceName);
    final result = _mapAndAssemble(
      summary.root,
      SourceFormat.astrobinCsv,
      sequenceName,
      forceUnsupported,
      forceImport,
    );
    return AstrobinImportResult(
      importResult: result,
      unresolved: summary.unresolved,
      resolvedRows: summary.resolvedRows,
      totalRows: summary.totalRows,
    );
  }

  /// Async variant for ICS imports so callers can surface unresolved
  /// VEVENTs (no RA/Dec in description) alongside the import result.
  Future<IcsCalendarImportResult> importIcsAsync(
    String content, {
    required bool forceUnsupported,
    bool forceImport = false,
    required String sequenceName,
  }) async {
    final summary = _ics.parse(content, sequenceName: sequenceName);
    final result = _mapAndAssemble(
      summary.root,
      SourceFormat.icsCalendar,
      sequenceName,
      forceUnsupported,
      forceImport,
    );
    return IcsCalendarImportResult(
      importResult: result,
      unresolved: summary.unresolved,
      totalEvents: summary.totalEvents,
    );
  }

  ImportResult _mapAndAssemble(
    CanonicalSequenceNode root,
    SourceFormat format,
    String sequenceName,
    bool forceUnsupported,
    bool forceImport,
  ) {
    final mapped = _mapper.map(
      root,
      sequenceName: sequenceName,
      forceUnsupported: forceUnsupported,
    );

    // In strict mode, unsupported nodes are a hard stop. The caller gets the
    // full list (not just the first) so they can show it in a dialog.
    if (!forceUnsupported && mapped.unsupported.isNotEmpty) {
      throw UnsupportedNodeError(mapped.unsupported);
    }

    // Run the unified validator over the assembled sequence. We do this
    // *after* the unsupported-node check so the user sees only one error
    // class at a time (force-import-unsupported, then validation). If
    // forceImport is set, we still run validation so the issues can be
    // surfaced in the summary dialog — just don't throw.
    // Mapper-sourced issues (e.g. indeterminate exposure counts under an
    // unbounded loop) precede the structural-validator output: they describe
    // information lost during the source→canonical→Sequence translation that
    // the assembled-Sequence validators cannot see.
    final issues = <ValidationIssue>[
      ...mapped.validationIssues,
      ..._validate(mapped.sequence),
    ];
    final hasErrors = issues.any((i) => i.severity == ValidationSeverity.error);

    final result = ImportResult(
      sourceFormat: format,
      totalNodes: mapped.totalNodes,
      mappingTable: mapped.mappingTable,
      droppedNodes: mapped.dropped,
      unsupportedNodes: mapped.unsupported,
      sequence: mapped.sequence,
      forcedImport: forceUnsupported && mapped.unsupported.isNotEmpty,
      validationIssues: issues,
    );

    if (hasErrors && !forceImport) {
      throw SequenceImportValidationFailedException(
        issues: issues,
        parsed: result,
      );
    }

    return result;
  }

  String _deriveSequenceName(String filePath) {
    final lastSep = filePath.lastIndexOf(RegExp(r'[\\/]'));
    final base = lastSep >= 0 ? filePath.substring(lastSep + 1) : filePath;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }
}

/// Bundles an [ImportResult] with the Astrobin-specific unresolved list.
class AstrobinImportResult {
  final ImportResult importResult;
  final List<UnresolvedTarget> unresolved;
  final int resolvedRows;
  final int totalRows;

  AstrobinImportResult({
    required this.importResult,
    required this.unresolved,
    required this.resolvedRows,
    required this.totalRows,
  });
}

/// Bundles an [ImportResult] with the ICS-specific unresolved list.
class IcsCalendarImportResult {
  final ImportResult importResult;
  final List<UnresolvedIcsEvent> unresolved;
  final int totalEvents;

  IcsCalendarImportResult({
    required this.importResult,
    required this.unresolved,
    required this.totalEvents,
  });
}
