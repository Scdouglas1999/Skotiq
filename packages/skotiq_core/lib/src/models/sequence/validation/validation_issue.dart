import '../sequence_models.dart';

/// Severity of a validation issue. Three levels:
///
///   * [error] — blocks sequence execution. The pre-flight dialog refuses to
///     start the sequence.
///   * [warning] — sequence will run but something is suspicious or could
///     misbehave at runtime.
///   * [info] — informational; no action required, but the user might want
///     to know.
enum ValidationSeverity { error, warning, info }

/// Coarse category used by the dialog UI to group issues. Adding a category
/// requires updating UI code that switches on it.
enum ValidationCategory {
  structure,
  targets,
  exposures,
  equipment,
  timing,
  settings,
  diskSpace,
  // Pre-flight checks. New categories so the pre-flight
  // dialog can group these in their own collapsible sections instead of
  // mixing them with the structural / equipment-connection issues.
  /// Dark library coverage (matching dark frames for the sequence's
  /// (gain, offset, temp, duration, binning) combinations).
  darkLibrary,

  /// Long-term equipment health (USB stability, focuser range, mount
  /// alignment freshness, time sync, cooler delta, filter wheel
  /// homing).
  equipmentHealth,

  /// Optical-train drift / pre-session calibration comparison.
  opticalTrain,
}

/// Display label for [ValidationCategory] — used by the dialog UI.
extension ValidationCategoryLabel on ValidationCategory {
  String get label {
    switch (this) {
      case ValidationCategory.structure:
        return 'Structure';
      case ValidationCategory.targets:
        return 'Targets';
      case ValidationCategory.exposures:
        return 'Imaging';
      case ValidationCategory.equipment:
        return 'Equipment';
      case ValidationCategory.timing:
        return 'Timing';
      case ValidationCategory.settings:
        return 'Settings';
      case ValidationCategory.diskSpace:
        return 'Storage';
      case ValidationCategory.darkLibrary:
        return 'Dark Library';
      case ValidationCategory.equipmentHealth:
        return 'Equipment Health';
      case ValidationCategory.opticalTrain:
        return 'Optical Train';
    }
  }
}

/// A single validation finding.
///
/// Plain immutable value class with const constructor + value equality. We
/// intentionally do not use freezed here — the equivalent value classes in
/// the sequence subsystem ([SequenceProgress] etc.) are also hand-rolled,
/// and the additional codegen would not buy us anything.
class ValidationIssue {
  final ValidationSeverity severity;
  final ValidationCategory category;
  final String title;
  final String description;

  /// Optional concrete hint the user can act on. Surfaced beneath the
  /// description in the pre-flight dialog.
  final String? resolutionHint;

  /// Optional id of the offending node. When present, the tree paints a
  /// matching coloured border / badge on that node.
  final String? affectedNodeId;

  /// Optional stable machine-readable code (e.g.
  /// `image_output_path_not_configured`). Set on issues that REST
  /// clients need to programmatically branch on so the wire payload
  /// doesn't depend on the human-readable `title` text.
  final String? code;

  const ValidationIssue({
    required this.severity,
    required this.category,
    required this.title,
    required this.description,
    this.resolutionHint,
    this.affectedNodeId,
    this.code,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ValidationIssue &&
          runtimeType == other.runtimeType &&
          severity == other.severity &&
          category == other.category &&
          title == other.title &&
          description == other.description &&
          resolutionHint == other.resolutionHint &&
          affectedNodeId == other.affectedNodeId &&
          code == other.code;

  @override
  int get hashCode => Object.hash(
    severity,
    category,
    title,
    description,
    resolutionHint,
    affectedNodeId,
    code,
  );

  @override
  String toString() =>
      'ValidationIssue($severity, $category, "$title"${affectedNodeId != null ? ", node=$affectedNodeId" : ""}${code != null ? ", code=$code" : ""})';
}

/// Aggregated result of running all validators against a sequence.
class ValidationResult {
  final List<ValidationIssue> issues;
  final DateTime validatedAt;

  const ValidationResult({required this.issues, required this.validatedAt});

  factory ValidationResult.empty() =>
      ValidationResult(issues: const [], validatedAt: DateTime.now());

  bool get hasErrors =>
      issues.any((i) => i.severity == ValidationSeverity.error);
  bool get hasWarnings =>
      issues.any((i) => i.severity == ValidationSeverity.warning);
  bool get hasInfo => issues.any((i) => i.severity == ValidationSeverity.info);

  /// Sequence may start iff there are no errors.
  bool get isValid => !hasErrors;

  int get errorCount =>
      issues.where((i) => i.severity == ValidationSeverity.error).length;
  int get warningCount =>
      issues.where((i) => i.severity == ValidationSeverity.warning).length;
  int get infoCount =>
      issues.where((i) => i.severity == ValidationSeverity.info).length;

  int get totalCount => issues.length;

  /// Returns issues grouped by `affectedNodeId`. Issues with a null
  /// affectedNodeId are not included.
  Map<String, List<ValidationIssue>> get issuesByNodeId {
    final byNode = <String, List<ValidationIssue>>{};
    for (final issue in issues) {
      final id = issue.affectedNodeId;
      if (id != null) {
        byNode.putIfAbsent(id, () => <ValidationIssue>[]).add(issue);
      }
    }
    return byNode;
  }

  /// Worst severity (error > warning > info) attached to a given node, or
  /// null if the node has no issues.
  ValidationSeverity? worstSeverityForNode(String nodeId) {
    final nodeIssues = issuesByNodeId[nodeId];
    if (nodeIssues == null || nodeIssues.isEmpty) return null;
    if (nodeIssues.any((i) => i.severity == ValidationSeverity.error)) {
      return ValidationSeverity.error;
    }
    if (nodeIssues.any((i) => i.severity == ValidationSeverity.warning)) {
      return ValidationSeverity.warning;
    }
    return ValidationSeverity.info;
  }
}

/// A single composable validator that knows how to check one specific class
/// of problem. Implementations should be small and grep-able — one rule per
/// class. Synchronous, and reads nothing but the sequence: a rule that needs
/// rig state or settings is a `RefAwareSequenceValidator`, and one that does
/// I/O an `AsyncSequenceValidator` (`providers/sequence/sequence_validation.dart`).
abstract class SequenceValidator {
  /// Stable, human-readable name. Used by debugging / logs and in test
  /// failure messages.
  String get name;

  /// Run this rule against a sequence. Implementations MUST NOT return null;
  /// return an empty list if the rule is clean. Implementations must not
  /// silently swallow missing context — if data is unavailable, emit an
  /// `info` severity issue explaining that the check could not run.
  List<ValidationIssue> validate(Sequence sequence);
}

/// Typed exception thrown by start paths (executor.start(),
/// sequence_action_service.start(), the headless POST /sequencer/start
/// handler) when pre-flight validation finds at least one
/// [ValidationSeverity.error] issue.
///
/// Carries the full [ValidationResult] so callers surface ALL findings; a
/// first-error-wins `Exception` truncates the rest and sends the operator back
/// for another round per error.
class SequenceValidationException implements Exception {
  /// Complete validation result. Includes errors, warnings, and info-level
  /// issues. Callers should typically only block on `result.errorCount`.
  final ValidationResult result;

  const SequenceValidationException(this.result);

  /// All blocking issues (severity == error). Convenience accessor.
  List<ValidationIssue> get errors => result.issues
      .where((i) => i.severity == ValidationSeverity.error)
      .toList(growable: false);

  /// Concise one-line summary suitable for a snackbar / log line. Includes
  /// the count and the title of every error (joined with `; `) so callers
  /// that simply `print(e)` still surface every blocking finding.
  @override
  String toString() {
    final errs = errors;
    if (errs.isEmpty) {
      // Defensive: callers should not throw this without errors, but if
      // they do we still produce a useful string instead of an empty one.
      return 'SequenceValidationException(no errors)';
    }
    final titles = errs.map((e) => e.title).join('; ');
    return 'Cannot start sequence: ${errs.length} validation '
        '${errs.length == 1 ? 'error' : 'errors'}: $titles';
  }

  /// Structured form for the headless API / remote callers. Mirrors the
  /// shape of the in-app pre-flight dialog so a remote dashboard can
  /// render the same UI as the desktop.
  Map<String, Object?> toJsonBody() => {
    'code': 'sequence_validation_failed',
    'message': toString(),
    'errorCount': result.errorCount,
    'warningCount': result.warningCount,
    'infoCount': result.infoCount,
    'issues': result.issues
        .map(
          (i) => {
            'severity': i.severity.name,
            'category': i.category.name,
            'title': i.title,
            'description': i.description,
            if (i.resolutionHint != null) 'resolutionHint': i.resolutionHint,
            if (i.affectedNodeId != null) 'affectedNodeId': i.affectedNodeId,
            if (i.code != null) 'code': i.code,
          },
        )
        .toList(),
  };
}
