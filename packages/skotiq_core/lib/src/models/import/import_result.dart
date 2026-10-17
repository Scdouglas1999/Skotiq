import 'package:equatable/equatable.dart';
import '../../providers/sequence/sequence_validation.dart';
import '../sequence/sequence_models.dart';
import 'canonical_sequence_node.dart';

/// Reason a source node was dropped during mapping.
enum DropReason {
  /// Decorative-only (annotation/comment). Always safe to drop.
  decorative,

  /// No Skotiq equivalent and user asked for "force import (drop
  /// unsupported)".
  unsupported,

  /// Node was disabled in the source file.
  disabled,
}

/// One row in the import summary's mapping table.
class MappingTableRow extends Equatable {
  /// Source-format type discriminator (e.g. `TakeExposure`,
  /// `NINA.Sequencer.SequenceItem.Imaging.TakeExposure`).
  final String sourceType;

  /// Skotiq [SequenceNode.nodeType] string the source mapped to.
  /// `null` means dropped (see [DroppedNodeRecord]).
  final String? skotiqType;

  /// How many times this mapping occurred.
  final int count;

  const MappingTableRow({
    required this.sourceType,
    required this.skotiqType,
    required this.count,
  });

  @override
  List<Object?> get props => [sourceType, skotiqType, count];
}

/// A node that was dropped from the import (either decorative or
/// force-import-dropped unsupported).
class DroppedNodeRecord extends Equatable {
  final String sourceType;
  final String name;
  final DropReason reason;

  const DroppedNodeRecord({
    required this.sourceType,
    required this.name,
    required this.reason,
  });

  @override
  List<Object?> get props => [sourceType, name, reason];
}

/// A node whose source type is recognized but has no Skotiq equivalent.
///
/// In strict mode (default), encountering any of these aborts the import via
/// [UnsupportedNodeError]. In force mode the importer collects them into
/// [ImportResult.unsupportedNodes] *and* re-files them in [droppedNodes] with
/// reason [DropReason.unsupported].
class UnsupportedNodeRecord extends Equatable {
  final String sourceType;
  final String name;

  /// Free-form explanation of why this isn't supported (e.g. "NINA's
  /// `SmartExposure` is a composite node Skotiq does not model").
  final String reason;

  const UnsupportedNodeRecord({
    required this.sourceType,
    required this.name,
    required this.reason,
  });

  @override
  List<Object?> get props => [sourceType, name, reason];
}

/// The result of parsing + mapping a source file. The UI shows this in the
/// summary dialog before the user confirms.
class ImportResult extends Equatable {
  final SourceFormat sourceFormat;

  /// Total number of source nodes we saw while parsing (including dropped /
  /// unsupported / decorative).
  final int totalNodes;

  final List<MappingTableRow> mappingTable;
  final List<DroppedNodeRecord> droppedNodes;
  final List<UnsupportedNodeRecord> unsupportedNodes;

  /// The fully-mapped Skotiq sequence, ready to persist or load into the
  /// editor.
  final Sequence sequence;

  /// True if the user asked for "force import" and there are nodes in
  /// [unsupportedNodes] that were dropped to satisfy that request.
  final bool forcedImport;

  /// Validation issues found after the sequence was assembled, sorted by
  /// severity. ERROR-severity issues block import unless the caller
  /// requests `forceImport: true` (in which case the user sees the
  /// issues and explicitly accepts them).
  ///
  /// Empty list = sequence passed structural validation. May contain
  /// warning- and info-level entries even when the sequence imported
  /// successfully; those are displayed in the import-summary dialog so
  /// the user can fix them before running the sequence.
  final List<ValidationIssue> validationIssues;

  const ImportResult({
    required this.sourceFormat,
    required this.totalNodes,
    required this.mappingTable,
    required this.droppedNodes,
    required this.unsupportedNodes,
    required this.sequence,
    this.forcedImport = false,
    this.validationIssues = const [],
  });

  bool get hasDropped => droppedNodes.isNotEmpty;
  bool get hasUnsupported => unsupportedNodes.isNotEmpty;

  /// True when there are validation issues at any severity.
  bool get hasValidationIssues => validationIssues.isNotEmpty;

  /// True when there are validation issues at ERROR severity. UI uses
  /// this to decide whether to show the "Import anyway" button.
  bool get hasValidationErrors =>
      validationIssues.any((i) => i.severity == ValidationSeverity.error);

  @override
  List<Object?> get props => [
    sourceFormat,
    totalNodes,
    mappingTable,
    droppedNodes,
    unsupportedNodes,
    sequence,
    forcedImport,
    validationIssues,
  ];
}

/// Thrown when the file's format can't be identified as NINA or SGP.
class UnknownFormatError implements Exception {
  final String message;
  final String? sniffedSnippet;

  UnknownFormatError(this.message, {this.sniffedSnippet});

  @override
  String toString() {
    if (sniffedSnippet != null) {
      return 'UnknownFormatError: $message (first bytes: $sniffedSnippet)';
    }
    return 'UnknownFormatError: $message';
  }
}

/// Thrown in strict mode when at least one node has no Skotiq equivalent.
class UnsupportedNodeError implements Exception {
  final List<UnsupportedNodeRecord> unsupported;

  UnsupportedNodeError(this.unsupported);

  @override
  String toString() {
    final names = unsupported.map((u) => u.sourceType).toSet().join(', ');
    final count = unsupported.length;
    return 'UnsupportedNodeError: $count node${count == 1 ? '' : 's'} '
        '${count == 1 ? 'has' : 'have'} no Skotiq equivalent: $names';
  }
}

/// Thrown when the source file is malformed (invalid JSON, missing required
/// keys, etc.). Distinct from [UnknownFormatError] so the UI can show the
/// underlying parse error instead of "couldn't sniff format".
class MalformedSourceError implements Exception {
  final String message;
  final Object? cause;

  MalformedSourceError(this.message, {this.cause});

  @override
  String toString() {
    if (cause != null) {
      return 'MalformedSourceError: $message (cause: $cause)';
    }
    return 'MalformedSourceError: $message';
  }
}

/// Thrown by [SequenceImporter.importFromString] / [importFromPath] when
/// the parsed sequence has at least one ERROR-severity validation issue
/// and the caller did not request `forceImport: true`.
///
/// Carries:
///   * [issues] — full list (errors + warnings + info) so the UI can
///     show them grouped by severity in a dialog.
///   * [parsed] — the assembled [ImportResult] (sequence is included)
///     so the UI can offer "Import anyway" without re-parsing the file.
class SequenceImportValidationFailedException implements Exception {
  final List<ValidationIssue> issues;
  final ImportResult parsed;

  SequenceImportValidationFailedException({
    required this.issues,
    required this.parsed,
  });

  /// Just the blocking issues. UI surfaces this list in the dialog body
  /// (warnings/info are de-emphasised below).
  List<ValidationIssue> get errors =>
      issues.where((i) => i.severity == ValidationSeverity.error).toList();

  @override
  String toString() {
    final blockers = errors.map((i) => i.title).toSet().join(', ');
    final blocking = errors.length;
    return 'SequenceImportValidationFailedException: $blocking '
        'blocking issue${blocking == 1 ? '' : 's'} [$blockers]; '
        '${issues.length} total.';
  }
}
