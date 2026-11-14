// The run's readers take each sequencer event in the codec's typed form. The
// payloads are produced the way production produces them: the native path
// encodes a typed bridge event, and the remote path sends that same event
// through the headless wire envelope (`{'type': 'event', ...toJson()}`,
// JSON-encoded) and back. Both must read the same.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';

const _capture = bridge.FrameCaptureMetadata(
  gain: 139,
  gainIsIso: false,
  offset: 21,
  sensorTempC: -9.5,
  exposureSecs: 120.0,
  binX: 2,
  binY: 2,
  frameType: 'Light',
);

void main() {
  SkotiqEvent local(bridge.SequencerEvent native) {
    final (eventType, data) = bridge.encodeEventPayload(
      bridge.EventPayload.sequencer(native),
    );
    return SkotiqEvent(
      timestamp: 1700000000123,
      severity: EventSeverity.info,
      category: EventCategory.sequencer,
      eventType: eventType,
      data: data,
    );
  }

  SkotiqEvent remote(SkotiqEvent event) {
    final wire = jsonEncode({
      'type': 'event',
      ...event.toJson(),
    }, toEncodable: (v) => v is BigInt ? v.toInt() : v);
    return SkotiqEvent.fromWireJson(jsonDecode(wire) as Map<String, dynamic>);
  }

  /// [native] as each transport delivers it.
  List<bridge.SequencerEvent> both(bridge.SequencerEvent native) {
    final event = local(native);
    return [sequencerEventOf(event)!, sequencerEventOf(remote(event))!];
  }

  bridge.SequencerEvent_InstructionProgressStructured report(
    String kind,
    Object? json,
  ) =>
      bridge.SequencerEvent.instructionProgressStructured(
            nodeId: 'n1',
            instruction: 'Frame watch',
            progressPercent: 100.0,
            detailKind: kind,
            detailJson: jsonEncode(json),
          )
          as bridge.SequencerEvent_InstructionProgressStructured;

  test('a non-sequencer event has no sequencer form', () {
    expect(
      sequencerEventOf(
        const SkotiqEvent(
          timestamp: 1,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ExposureStarted',
          data: {},
        ),
      ),
      isNull,
    );
  });

  test('stopped, completed and failed end the run; paused does not', () {
    expect(const bridge.SequencerEvent.stopped().endsRun, isTrue);
    expect(const bridge.SequencerEvent.completed().endsRun, isTrue);
    expect(const bridge.SequencerEvent.failed(error: 'x').endsRun, isTrue);
    expect(const bridge.SequencerEvent.paused().endsRun, isFalse);
  });

  test('a step verdict reads as its node status', () {
    NodeStatus of(String status) =>
        (bridge.SequencerEvent.nodeCompleted(nodeId: 'n', status: status)
                as bridge.SequencerEvent_NodeCompleted)
            .nodeStatus;
    expect(of('success'), NodeStatus.success);
    expect(of('skipped'), NodeStatus.skipped);
    expect(of('cancelled'), NodeStatus.cancelled);
    expect(of('failed'), NodeStatus.failure);
    expect(of('something new'), NodeStatus.failure);
  });

  test('a performed dither is its own report on both transports', () {
    for (final e in both(report(ditherPerformedDetailKind, {}))) {
      expect(e, isA<bridge.SequencerEvent_InstructionProgressStructured>());
      final structured =
          e as bridge.SequencerEvent_InstructionProgressStructured;
      expect(structured.reportsDither, isTrue);
      expect(structured.frameAssessment, isNull);
    }
  });

  test('a frame assessment is read on both transports', () {
    for (final e in both(
      report(frameAssessedDetailKind, {
        'save_path': r'C:\data\NGC0891\B_0120.fits',
        'filter': 'B',
        'exposure_secs': 120,
        'was_accepted': true,
        'solve_attempted': true,
        'plate_solved': true,
        'solved_ra_deg': 35.64,
        'solved_dec_deg': 42.35,
        'solved_rotation_deg': null,
        'solved_pixel_scale': 1.12,
        'offset_arcmin': 31.6,
        'guide_rms_total': 0.74,
        'guide_rms_samples': 58,
        'background_adu': 801.5,
        'star_count': 640,
        'altitude_deg': 66.1,
        'azimuth_deg': 283.0,
        'pier_side': 'East',
        'off_target': true,
        'obstructed': false,
        'exclusion_reason': 'Off target: 31.6 arcmin from NGC 891',
      }),
    )) {
      final assessment =
          (e as bridge.SequencerEvent_InstructionProgressStructured)
              .frameAssessment!;
      expect(assessment.savePath, r'C:\data\NGC0891\B_0120.fits');
      expect(assessment.exposureSecs, 120.0);
      expect(assessment.solvedRaDeg, 35.64);
      expect(assessment.solvedRotationDeg, isNull);
      expect(assessment.guideRmsSamples, 58);
      expect(assessment.offTarget, isTrue);
      expect(assessment.isExcluded, isTrue);
    }
  });

  test('a horizon obstruction is read, and one without a position is not', () {
    for (final e in both(
      report(horizonObstructionDetailKind, {
        'altitude_deg': 64.0,
        'azimuth_deg': 286.2,
        'target_name': 'NGC 891',
        'latitude': 43.1,
        'longitude': -77.6,
        'verdict': 'obstruction',
        'action': 'next_target',
        'message': 'Trees ahead.',
      }),
    )) {
      final obstruction =
          (e as bridge.SequencerEvent_InstructionProgressStructured)
              .horizonObstruction!;
      expect(obstruction.azimuthDeg, 286.2);
      expect(obstruction.action, 'next_target');
      expect(obstruction.latitude, 43.1);
    }
    expect(report(horizonObstructionDetailKind, {}).horizonObstruction, isNull);
  });

  test('graded frames carry capture truth and paths on both transports', () {
    for (final e in both(
      const bridge.SequencerEvent.frameAccepted(
        nodeId: 'n1',
        frame: 2,
        total: 5,
        hfr: 2.4,
        starCount: 812,
        acceptedTotal: 2,
        rejectedTotal: 0,
        savePath: '/data/M31/L_0002.fits',
        capture: _capture,
      ),
    )) {
      final verdict = FrameVerdict.of(e)!;
      expect(verdict.accepted, isTrue);
      expect(verdict.filePath, '/data/M31/L_0002.fits');
      expect(verdict.starCount, 812);
      expect(verdict.capture.gain, 139);
      expect(verdict.capture.exposureSecs, 120.0);
    }
    for (final e in both(
      const bridge.SequencerEvent.frameRejected(
        nodeId: 'n1',
        frame: 3,
        total: 5,
        reason: 'HFR 6.1 over limit',
        rejectPath: '/data/M31/Reject/L_0003.fits',
        consecutiveRejects: 1,
        acceptedTotal: 2,
        rejectedTotal: 1,
        evidence: [],
        capture: _capture,
      ),
    )) {
      final verdict = FrameVerdict.of(e)!;
      expect(verdict.accepted, isFalse);
      expect(verdict.filePath, '/data/M31/Reject/L_0003.fits');
      expect(verdict.reason, 'HFR 6.1 over limit');
      expect(verdict.capture.binX, 2);
    }
    expect(FrameVerdict.of(const bridge.SequencerEvent.paused()), isNull);
  });

  test('an old spelling of a run event is not a run event', () {
    final event = SkotiqEvent.fromWireJson({
      'timestamp': 1,
      'severity': 'info',
      'category': 'sequencer',
      'eventType': 'SequencePaused',
      'data': <String, dynamic>{},
    });
    expect(sequencerEventOf(event), isNull);
  });
}
