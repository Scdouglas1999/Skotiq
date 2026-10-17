/// Admission assessment for an unattended scheduler start.
enum SchedulerReadinessSeverity { warning, blocker }

enum SchedulerReadinessIssueId {
  camera,
  mount,
  location,
  outputPath,
  solver,
  weather,
  guider,
  dawn,
  disk,
  remoteCompatibility,
}

class SchedulerReadinessIssue {
  final SchedulerReadinessIssueId id;
  final SchedulerReadinessSeverity severity;
  final String title;
  final String detail;

  const SchedulerReadinessIssue({
    required this.id,
    required this.severity,
    required this.title,
    required this.detail,
  });

  Map<String, dynamic> toStorageJson() => {
    'id': id.name,
    'severity': severity.name,
    'title': title,
    'detail': detail,
  };

  static SchedulerReadinessIssue? fromStorageJson(dynamic value) {
    if (value is! Map) return null;
    final id = SchedulerReadinessIssueId.values.where(
      (candidate) => candidate.name == value['id'],
    );
    final severity = SchedulerReadinessSeverity.values.where(
      (candidate) => candidate.name == value['severity'],
    );
    final title = value['title'];
    final detail = value['detail'];
    if (id.length != 1 ||
        severity.length != 1 ||
        title is! String ||
        detail is! String) {
      return null;
    }
    return SchedulerReadinessIssue(
      id: id.single,
      severity: severity.single,
      title: title,
      detail: detail,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SchedulerReadinessIssue &&
          other.id == id &&
          other.severity == severity &&
          other.title == title &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(id, severity, title, detail);
}

class SchedulerStartReadiness {
  final List<SchedulerReadinessIssue> issues;
  final bool available;
  final bool solverRequired;

  const SchedulerStartReadiness({
    required this.issues,
    required this.available,
    required this.solverRequired,
  });

  const SchedulerStartReadiness.unavailable()
    : issues = const [
        SchedulerReadinessIssue(
          id: SchedulerReadinessIssueId.remoteCompatibility,
          severity: SchedulerReadinessSeverity.blocker,
          title: 'Host readiness unavailable',
          detail: 'Update the imaging host before starting unattended.',
        ),
      ],
      available = false,
      solverRequired = false;

  bool get blocked =>
      issues.any(
        (issue) => issue.severity == SchedulerReadinessSeverity.blocker,
      ) ||
      !available;
  List<SchedulerReadinessIssue> get warnings => issues
      .where((issue) => issue.severity == SchedulerReadinessSeverity.warning)
      .toList(growable: false);
  List<SchedulerReadinessIssue> get blockers => issues
      .where((issue) => issue.severity == SchedulerReadinessSeverity.blocker)
      .toList(growable: false);

  Map<String, dynamic> toStorageJson() => {
    'available': available,
    'solverRequired': solverRequired,
    'issues': [for (final issue in issues) issue.toStorageJson()],
  };

  static SchedulerStartReadiness fromStorageJson(dynamic value) {
    if (value is! Map ||
        value['available'] is! bool ||
        value['issues'] is! List ||
        value['solverRequired'] is! bool) {
      return const SchedulerStartReadiness.unavailable();
    }
    if (value['available'] != true) {
      return const SchedulerStartReadiness.unavailable();
    }
    final issues = <SchedulerReadinessIssue>[];
    for (final raw in value['issues'] as List) {
      final issue = SchedulerReadinessIssue.fromStorageJson(raw);
      if (issue == null) return const SchedulerStartReadiness.unavailable();
      issues.add(issue);
    }
    return SchedulerStartReadiness(
      issues: issues,
      available: value['available'] as bool,
      solverRequired: value['solverRequired'] as bool,
    );
  }

  /// Value equality so a recomputed-but-identical assessment does not wake
  /// every watcher. The readiness provider rebuilds on each safety evaluation
  /// and returns a fresh instance even when nothing about the rig changed.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SchedulerStartReadiness) return false;
    if (other.available != available ||
        other.solverRequired != solverRequired ||
        other.issues.length != issues.length) {
      return false;
    }
    for (var i = 0; i < issues.length; i++) {
      if (other.issues[i] != issues[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(available, solverRequired, Object.hashAll(issues));
}
