// Where the scheduler's own diagnostics go.
//
// `dart:developer` alone has NO destination in a shipping Flutter build that
// the operator (or an auditor) can reach:
//
//   * the rolling `skotiq.log.<date>` on disk is written by the Rust
//     tracing appender and carried 0 SchedulerEngine lines, and
//   * Settings > Advanced > Logs reads LoggingService's in-memory ring, which
//     `dart:developer` never feeds — its source dropdown offered only
//     `SequenceExecutor`.
//
// A `dart:developer`-only reconcile line — the one piece of evidence that says
// WHICH engine instance re-armed the autopilot — is therefore uncheckable after
// the fact.
//
// The engine keeps writing to `dart:developer` (useful under a debugger) and
// ALSO writes to an injectable [SchedulerLogSink]. The Riverpod wiring binds
// that sink to [LoggingService], which puts scheduler diagnostics into the
// in-app Logs viewer, `/api/logs/recent` + `/api/logs/tail`, and the on-disk
// diagnostic export (`LoggingService.exportLogs` appends the in-memory Dart
// entries after the native files).

import '../logging_service.dart';

/// Severity of a scheduler diagnostic, in the engine's own vocabulary so the
/// pure-logic core does not depend on the logging stack.
enum SchedulerLogLevel {
  /// Trace detail; only interesting when reconstructing a night.
  trace,

  /// Something the operator or an auditor would want to find later.
  info,

  /// The autopilot declined to act, or acted degraded.
  warning,
}

/// Sink the engine hands each diagnostic to. `null` means "developer log only".
typedef SchedulerLogSink = void Function(SchedulerLogLevel level, String msg);

/// The `source` every scheduler diagnostic is filed under. This is the string
/// the Logs viewer's source dropdown offers and that a `grep Scheduler` over an
/// exported log matches, so it is a constant rather than a literal per call.
const String kSchedulerLogSource = 'SchedulerEngine';

/// Adapt [logger] into a [SchedulerLogSink].
SchedulerLogSink schedulerLogSinkFor(LoggingService logger) {
  return (level, message) {
    switch (level) {
      case SchedulerLogLevel.trace:
        logger.debug(message, source: kSchedulerLogSource);
      case SchedulerLogLevel.info:
        logger.info(message, source: kSchedulerLogSource);
      case SchedulerLogLevel.warning:
        logger.warning(message, source: kSchedulerLogSource);
    }
  };
}
