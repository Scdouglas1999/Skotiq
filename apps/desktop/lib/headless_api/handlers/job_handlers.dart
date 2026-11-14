// REST surface for the JobManager.
//
// Exposes:
//   GET    /api/jobs/{jobId}          - current job snapshot
//   GET    /api/jobs                  - list jobs (filter by state/operation)
//   POST   /api/jobs/{jobId}/cancel   - request cooperative cancellation
//   DELETE /api/jobs/{jobId}          - purge a terminated job

import 'package:shelf/shelf.dart';

import '../job_manager.dart';
import '../response_helpers.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

/// Handlers for the long-running-operations job model.
///
/// shelf_router passes URL path parameters as positional arguments to the
/// handler — the same convention `target_handlers.dart` and
/// `sequence_management_handlers.dart` follow. We declare the second
/// parameter explicitly rather than reading from `request.context` so
/// the wiring stays consistent with the rest of the handler module.
class JobHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    JobApi.listJobs: handleListJobs,
    JobApi.getJob: handleGetJob,
    JobApi.cancelJob: handleCancelJob,
    JobApi.purgeJob: handlePurgeJob,
  };

  final JobManager jobManager;

  JobHandlers({required this.jobManager});

  /// `GET /api/jobs/{jobId}` — return the current snapshot. 404 when the
  /// job is unknown (already purged, never registered, or the cached id
  /// is from a previous server instance).
  Future<Response> handleGetJob(Request request, String jobId) async {
    if (jobId.isEmpty) {
      return jsonBadRequest({
        'error': 'invalid_job_id',
        'message': 'jobId path segment must not be empty.',
      });
    }
    final job = jobManager.get(jobId);
    if (job == null) {
      return jsonNotFound({'error': 'job_not_found', 'jobId': jobId});
    }
    return jsonOk(job.toJson());
  }

  /// `GET /api/jobs?state=running&operation=plate-solve&limit=N` — list
  /// jobs. State / operation are optional filters. Limit caps the response
  /// size (server-side enforced 200 default).
  Future<Response> handleListJobs(Request request) async {
    final query = request.url.queryParameters;
    JobState? state;
    final stateParam = query['state'];
    if (stateParam != null && stateParam.isNotEmpty) {
      state = parseJobState(stateParam);
      if (state == null) {
        return jsonBadRequest({
          'error': 'invalid_state',
          'message':
              'Unknown job state "$stateParam". Expected one of: '
              '${JobState.values.map((s) => s.wireName).join(", ")}.',
        });
      }
    }
    final operation = query['operation'];
    int limit = 200;
    final limitParam = query['limit'];
    if (limitParam != null && limitParam.isNotEmpty) {
      final parsed = int.tryParse(limitParam);
      if (parsed == null || parsed <= 0 || parsed > 1000) {
        return jsonBadRequest({
          'error': 'invalid_limit',
          'message':
              'limit must be a positive integer no larger than 1000 (got "$limitParam").',
        });
      }
      limit = parsed;
    }
    final jobs = jobManager.list(
      state: state,
      operation: (operation == null || operation.isEmpty) ? null : operation,
      limit: limit,
    );
    return jsonOk({
      'jobs': jobs.map((j) => j.toJson()).toList(),
      'total': jobs.length,
    });
  }

  /// `POST /api/jobs/{jobId}/cancel` — request cancellation.
  /// 404 when the job is unknown.
  /// 409 when the job is already terminal.
  /// 200 with the post-cancel snapshot otherwise (state may still be
  /// `running` if the work hasn't polled the cancellation token yet).
  Future<Response> handleCancelJob(Request request, String jobId) async {
    if (jobId.isEmpty) {
      return jsonBadRequest({
        'error': 'invalid_job_id',
        'message': 'jobId path segment must not be empty.',
      });
    }
    try {
      final job = jobManager.cancel(jobId);
      if (job == null) {
        return jsonNotFound({'error': 'job_not_found', 'jobId': jobId});
      }
      return jsonOk(job.toJson());
    } on StateError catch (e) {
      // The job is already terminal — cancellation cannot apply.
      return jsonConflict({
        'error': 'job_terminal',
        'jobId': jobId,
        'message': e.message,
      });
    }
  }

  /// `DELETE /api/jobs/{jobId}` — purge a terminated job from the
  /// in-memory store. 404 when the job is unknown, 409 when still live.
  Future<Response> handlePurgeJob(Request request, String jobId) async {
    if (jobId.isEmpty) {
      return jsonBadRequest({
        'error': 'invalid_job_id',
        'message': 'jobId path segment must not be empty.',
      });
    }
    final job = jobManager.get(jobId);
    if (job == null) {
      return jsonNotFound({'error': 'job_not_found', 'jobId': jobId});
    }
    if (!job.state.isTerminal) {
      return jsonConflict({
        'error': 'job_still_running',
        'jobId': jobId,
        'state': job.state.wireName,
        'message': 'Cancel the job before purging it.',
      });
    }
    final removed = jobManager.purge(jobId);
    return jsonOk({'jobId': jobId, 'purged': removed});
  }
}
