import 'dart:typed_data';

import 'package:skotiq_core/skotiq_core.dart';


/// Sessions, captured-image rows and targets in a linked imaging host's
/// database, as wire rows.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostImagingRecords {
  Future<int> createCapturedImage(Map<String, dynamic> image);

  Future<int> createSession(Map<String, dynamic> session);

  Future<void> endSession(int id, {String status = 'completed'});

  Future<List<Map<String, dynamic>>> getAllSessions();

  Future<List<Map<String, dynamic>>> getAllTargets();

  Future<Map<String, dynamic>?> getCapturedImageById(int id);

  Future<List<Map<String, dynamic>>> getImagesByProducingNode(
    String producingNodeId, {
    String? producingRunId,
    int? limit,
  });

  Future<List<Map<String, dynamic>>> getImagesForTarget(int targetId);

  Future<Map<String, dynamic>?> getSessionById(int id);

  Future<List<Map<String, dynamic>>> getSessionImageRows(int sessionId);

  Future<List<Map<String, dynamic>>> getSessionsForTarget(int targetId);

  Future<void> updateCapturedImage(int id, Map<String, dynamic> patch);

  Future<void> updateSession(int id, Map<String, dynamic> body);

  Future<int> createTarget(Map<String, dynamic> target);

  Future<RemotePage<RemoteSequenceRun>> fetchSequenceRuns({
    int? sequenceId,
    int limit = 200,
    int offset = 0,
  });

  Future<List<Map<String, dynamic>>> getAllImages();

  Future<List<Map<String, dynamic>>> getAllImageRows();

  Future<Uint8List> getImageThumbnail(int imageId);

  Future<int> countUntrackedTargets();

  Future<int> removeUntrackedTargets();

  Future<List<Map<String, dynamic>>> searchTargets(String query);

  Future<void> updateTarget(int id, Map<String, dynamic> target);

  Future<List<Map<String, dynamic>>> getStandaloneImageRows();

  Future<RemoteSequenceRunDetail> fetchSequenceRunById(int runId);

  Future<RemoteReplayEventsPage> fetchSequenceRunEvents(
    int runId, {
    int? sinceMs,
    int? untilMs,
    String? severityMin,
    int limit = 200,
    int offset = 0,
  });

  Future<RemotePage<RemoteReplayFrame>> fetchSequenceRunFrames(
    int runId, {
    int limit = 200,
    int offset = 0,
  });
}
