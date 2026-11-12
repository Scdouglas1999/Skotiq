import 'package:skotiq_remote_protocol/wire_models.dart';

/// Long-running jobs a linked imaging host runs for its clients.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostJobs {
  Future<RemoteJob> awaitJobCompletion(
    String jobId, {
    Duration timeout,
    Duration pollInterval,
  });
}
