import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

SchedulerReadinessIssue issue(
  SchedulerReadinessIssueId id,
  SchedulerReadinessSeverity severity,
) =>
    SchedulerReadinessIssue(
      id: id,
      severity: severity,
      title: id.name,
      detail: severity.name,
    );

void main() {
  test('camera, mount, location, and output blockers prevent unattended start',
      () {
    final result = SchedulerStartReadiness(
      issues: [
        issue(SchedulerReadinessIssueId.camera,
            SchedulerReadinessSeverity.blocker),
        issue(SchedulerReadinessIssueId.location,
            SchedulerReadinessSeverity.blocker),
        issue(SchedulerReadinessIssueId.outputPath,
            SchedulerReadinessSeverity.blocker),
      ],
      available: true,
      solverRequired: true,
    );

    expect(result.blockers.map((entry) => entry.id), [
      SchedulerReadinessIssueId.camera,
      SchedulerReadinessIssueId.location,
      SchedulerReadinessIssueId.outputPath,
    ]);
    expect(result.warnings, isEmpty);
  });

  test('auxiliary and solver warnings are explicit confirmation signals', () {
    final result = SchedulerStartReadiness(
      issues: [
        issue(SchedulerReadinessIssueId.guider,
            SchedulerReadinessSeverity.warning),
        issue(SchedulerReadinessIssueId.weather,
            SchedulerReadinessSeverity.warning),
        issue(
            SchedulerReadinessIssueId.dawn, SchedulerReadinessSeverity.warning),
      ],
      available: true,
      solverRequired: true,
    );

    expect(result.blockers, isEmpty);
    expect(result.warnings.map((entry) => entry.id), [
      SchedulerReadinessIssueId.guider,
      SchedulerReadinessIssueId.weather,
      SchedulerReadinessIssueId.dawn,
    ]);
  });

  test('a required solver is a hard blocker, not a warning', () {
    final result = SchedulerStartReadiness(
      issues: [
        issue(SchedulerReadinessIssueId.solver,
            SchedulerReadinessSeverity.blocker)
      ],
      available: true,
      solverRequired: true,
    );

    expect(result.blockers.single.id, SchedulerReadinessIssueId.solver);
    expect(result.warnings, isEmpty);
  });

  test('unavailable or malformed remote readiness remains visibly blocked', () {
    final unavailable = SchedulerStartReadiness.fromStorageJson({
      'available': false,
      'solverRequired': true,
      'issues': <Object?>[],
    });
    final malformed = SchedulerStartReadiness.fromStorageJson({
      'available': true,
      'solverRequired': true,
      'issues': [
        {'id': 'unknown', 'severity': 'warning', 'title': 'x', 'detail': 'y'},
      ],
    });

    expect(unavailable.blocked, isTrue);
    expect(unavailable.blockers, isNotEmpty);
    expect(malformed.blocked, isTrue);
    expect(malformed.blockers, isNotEmpty);
  });
}
