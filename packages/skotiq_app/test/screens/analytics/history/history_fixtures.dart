import 'dart:convert';

import 'package:skotiq_core/database.dart';

ImagingSession session(
  int id, {
  String? name,
  required DateTime start,
  DateTime? end,
  String status = 'completed',
  int? targetId,
  int? sequenceId,
  int exposures = 0,
  double integration = 0,
  double? hfr,
  double? rms,
  int autofocus = 0,
}) =>
    ImagingSession(
      id: id,
      name: name,
      startTime: start,
      endTime: end,
      targetId: targetId,
      sequenceId: sequenceId,
      totalExposures: exposures,
      successfulExposures: exposures,
      failedExposures: 0,
      totalIntegrationSecs: integration,
      avgHfr: hfr,
      avgGuidingRms: rms,
      autofocusCount: autofocus,
      status: status,
    );

SequenceRun run(
  int id, {
  required String name,
  required DateTime start,
  DateTime? end,
  String status = 'completed',
  int? sequenceId,
  Map<String, Object?> stats = const {},
}) =>
    SequenceRun(
      id: id,
      sequenceId: sequenceId,
      sequenceName: name,
      startedAt: start,
      endedAt: end,
      status: status,
      statsJson: jsonEncode(stats),
    );

DbCapturedImage frame(
  int id, {
  int? sessionId,
  String type = 'light',
  bool accepted = true,
  double exposure = 60,
  required DateTime at,
  double? hfr,
  double? rms,
  double? temperature,
}) =>
    DbCapturedImage(
      id: id,
      sessionId: sessionId,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: type,
      exposureDuration: exposure,
      binX: 1,
      binY: 1,
      capturedAt: at,
      createdAt: at,
      isAccepted: accepted,
      isPlateSolved: false,
      hfr: hfr,
      guidingRmsTotal: rms,
      sensorTemp: temperature,
    );
