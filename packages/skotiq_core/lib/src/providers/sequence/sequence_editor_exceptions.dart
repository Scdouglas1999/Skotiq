import '../../models/sequence/sequence_models.dart';
import 'sequence_validation.dart';

/// Base type for editor-side errors raised by [CurrentSequenceNotifier].
///
/// Defined as a sealed class so callers can `switch` exhaustively over the
/// known editor failure modes when surfacing them in the UI. New exception
/// types must extend this class.
sealed class SequenceEditorException implements Exception {
  const SequenceEditorException(this.message);

  /// Human-readable explanation suitable for surfacing to the user verbatim.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when a mutating editor operation is attempted while the sequence
/// is actively running (Running / Paused / Stopping).
///
/// The executor owns sequence state during these phases; editing the tree
/// underneath it would either be silently ignored by the running native
/// engine or — worse — corrupt the checkpoint replay state. Callers (UI)
/// should gate the action up-front via [canEditSequenceProvider] but the
/// notifier is the last line of defense.
class SequenceLockedException extends SequenceEditorException {
  const SequenceLockedException({
    required this.attemptedOperation,
    required this.executionState,
  }) : super(
         'Cannot $attemptedOperation while sequence is $executionState. '
         'Stop the sequence first.',
       );

  /// The operation the caller tried to perform (e.g. "add node",
  /// "reorder targets"). Verb phrase, not capitalized, no trailing period.
  final String attemptedOperation;

  /// The execution state that triggered the lock. One of `running`,
  /// `paused`, or `stopping`.
  final SequenceExecutionState executionState;
}

/// Thrown by snippet/clipboard deserialization when a node JSON payload
/// carries a `nodeType` discriminator the editor does not recognize.
///
/// Substituting an `InstructionSetNode` would collapse the snippet's
/// semantics — an unknown `MeridianFlip` becomes a no-op container at runtime.
/// Throwing surfaces the schema mismatch so the importer can decide whether to
/// show it to the user, log it, or abort the snippet insertion.
class SnippetDeserializationException extends SequenceEditorException {
  const SnippetDeserializationException({
    required this.unknownType,
    required this.snippetName,
  }) : super(
         'Snippet "$snippetName" references unknown node type "$unknownType". '
         'The snippet may have been authored by a newer version of Skotiq.',
       );

  /// The raw `nodeType` string from the snippet JSON that could not be
  /// resolved (kept verbatim — not normalized — so users can search the
  /// snippet file for it).
  final String unknownType;

  /// Name of the snippet the bad node was inside. Used in the error
  /// message so the user can identify which snippet to fix.
  final String snippetName;
}

/// Thrown when an operation requires a current sequence to exist but
/// none has been loaded or created.
///
/// Mutating methods such as `addTargetHeader` must throw rather than paper
/// over it by calling `createSequence()`: an implicit unnamed sequence hides
/// from the user that they never opened one, and makes the editor
/// non-idempotent. Callers catch this and prompt.
class NoActiveSequenceException extends SequenceEditorException {
  const NoActiveSequenceException({required this.attemptedOperation})
    : super(
        'Cannot $attemptedOperation: no active sequence. '
        'Create or open a sequence first.',
      );

  /// The operation the caller tried to perform. Verb phrase, not
  /// capitalized, no trailing period (e.g. "add a target").
  final String attemptedOperation;
}

/// Thrown by [CurrentSequenceNotifier.reorderTargets] when the source and
/// destination targets do not share the same parent container.
///
/// Reordering across parents would require choosing semantics (move? copy?
/// adopt-orphans?) that the bulk reorder API doesn't express. UI should
/// catch and explain.
class CrossParentReorderException extends SequenceEditorException {
  const CrossParentReorderException({
    required this.sourceTargetName,
    required this.destinationTargetName,
  }) : super(
         'Cannot reorder "$sourceTargetName" across "$destinationTargetName": '
         'targets are under different parents. Move them into the same '
         'container first.',
       );

  final String sourceTargetName;
  final String destinationTargetName;
}

/// Thrown by `SequenceFileService.exportSequence` when the sequence has
/// validation errors that would make the exported file refuse to round-trip
/// back through the importer.
///
/// Carries the underlying [ValidationIssue] list so the UI can show
/// the user exactly what to fix, then offer a "Force export anyway" path
/// via `forceExport: true`.
class SequenceValidationFailedException extends SequenceEditorException {
  SequenceValidationFailedException(this.issues) : super(_buildMessage(issues));

  final List<ValidationIssue> issues;

  static String _buildMessage(List<ValidationIssue> issues) {
    final errors = issues
        .where((i) => i.severity == ValidationSeverity.error)
        .map((i) => '  - ${i.title}: ${i.description}')
        .join('\n');
    return 'Sequence has ${issues.length} validation '
        'issue${issues.length == 1 ? '' : 's'} blocking export:\n'
        '$errors';
  }
}

/// Thrown by [CurrentSequenceNotifier.createSequence] / [loadSequence]
/// when called with a current sequence that has unsaved edits and the
/// caller did not opt into discarding them via `discardUnsaved: true`.
///
/// The editor tracks "dirty since last save" internally — every mutating
/// method flips the flag, and the snippet-library save / file-export /
/// repository persist paths clear it via [CurrentSequenceNotifier.markSaved].
/// The UI is expected to catch this exception and show a "Discard unsaved
/// changes?" confirmation before retrying with `discardUnsaved: true`.
class UnsavedChangesException extends SequenceEditorException {
  const UnsavedChangesException({
    required this.attemptedOperation,
    required this.currentSequenceName,
  }) : super(
         'Cannot $attemptedOperation: "$currentSequenceName" has unsaved '
         'changes. Save or discard them first.',
       );

  /// Verb phrase describing what was blocked (e.g. "create a new sequence",
  /// "open imported sequence"). Lower-case, no trailing period.
  final String attemptedOperation;

  /// Name of the in-editor sequence whose unsaved edits triggered the
  /// guard. Included so the UI can show it in the confirmation prompt.
  final String currentSequenceName;
}
