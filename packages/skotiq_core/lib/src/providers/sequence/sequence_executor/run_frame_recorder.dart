import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../backend/frame_capture_metadata.dart';
import '../../../backend/network_backend.dart' show NetworkBackend;
import '../../../backend/skotiq_backend.dart';
import '../../../database/daos/campaigns_dao.dart' show campaignsDaoProvider;
import '../../../models/imaging/imaging_models.dart';
import '../../../services/capture_preview_loader.dart';
import '../../../services/frame_quality_score.dart';
import '../../../services/logging_service.dart';
import '../../../services/science/science_processing_service.dart'
    show scienceProcessingServiceProvider;
import '../../dark_library_provider.dart' show darkLibraryServiceProvider;
import '../../database_provider.dart' show imagesDaoProvider;
import '../../equipment_provider.dart';
import '../../frame_record_updates.dart';
import '../../imaging_provider.dart';
import '../../sequence_stats_provider.dart';
import '../../session_provider.dart';
import '../../thumbnail_sidecar_provider.dart';
import '../sequence_progress.dart' show sequenceProgressProvider;
import '../sequencer_run_event.dart';
import '../../sequence_provider.dart' show currentSequenceProvider;
import 'frame_attribution.dart';
import 'run_frame_science.dart';
import 'run_stats_ledger.dart';
import 'run_target_binding.dart';

/// Everything a run records about a frame it captured: the run-stats frame
/// counters, the `captured_images` row, the imaging-session counters, the
/// campaign credit and the live preview.
///
/// Counting rule. `FrameAccepted` / `FrameRejected` are the only events every
/// producer emits for a saved frame (native synthesizes `ExposureCompleted`
/// only for TakeExposure nodes whose frame index advances, never for Smart
/// Exposure), so the counters move on the grader's verdict. The verdict is
/// held by frame index until that frame's `ExposureCompleted`, which then adds
/// nothing; a frame that completes with no verdict was never graded (no save
/// path) and is counted on completion instead. Verdicts are dropped when a new
/// node starts, since frame indices restart per node.
class RunFrameRecorder {
  RunFrameRecorder({
    required Ref ref,
    required SkotiqBackend backend,
    required RunStatsLedger stats,
    required RunTargetBinding targets,
    required LoggingService Function() logger,
    required bool Function() isDisposed,
  }) : _ref = ref,
       _backend = backend,
       _stats = stats,
       _targets = targets,
       _loggerFn = logger,
       _isDisposed = isDisposed;

  final Ref _ref;
  final SkotiqBackend _backend;
  final RunStatsLedger _stats;
  final RunTargetBinding _targets;
  final LoggingService Function() _loggerFn;
  final bool Function() _isDisposed;
  LoggingService get _logger => _loggerFn();

  /// Light frames' hand-off to the per-frame science pipeline.
  late final RunFrameScience _science = RunFrameScience(logger: _loggerFn);

  /// Verdicts already counted, by frame index, awaiting their
  /// `ExposureCompleted`.
  final Map<int, ({bool accepted, FrameCapture capture})> _graded =
      <int, ({bool accepted, FrameCapture capture})>{};

  /// Frame persistence still in flight.
  final Set<Future<void>> _inFlight = <Future<void>>{};

  /// How each recent graded frame was counted, by the path it was saved at,
  /// so the frame watch's later exclusion moves it out of the bucket it was
  /// counted in. Bounded: an assessment arrives within a frame or two.
  final Map<String, _CountedFrame> _countedByPath = <String, _CountedFrame>{};
  static const int _countedFramesKept = 64;

  /// The persistence futures in flight, for tests waiting on quiescence.
  List<Future<void>> get inFlightRegistrations => List.of(_inFlight);

  /// Forget held verdicts: a new run, or a new node whose frame 1 must not
  /// meet an aborted burst's verdict.
  void clearVerdicts() => _graded.clear();

  /// Count a graded frame, show it, and hold its verdict for its
  /// `ExposureCompleted`. The exposure credited is the one the camera
  /// reported, the value the FITS header and the row are written from.
  void recordGraded(FrameGraded event) {
    final capture = event.capture;
    final exposureSecs = capture.exposureSecs ?? 0.0;
    final bucket = recordRunFrame(
      exposureSecs: exposureSecs,
      filter: event.filter,
      accepted: event.accepted,
    );
    // The saved file travels with the preview so the background solve and the
    // star overlay can find it. A Smart Exposure frame never gets an
    // `ExposureCompleted`, so the verdict is where it goes on screen.
    final path = event.filePath;
    if (path != null && path.isNotEmpty) {
      _countedByPath.remove(path);
      _countedByPath[path] = _CountedFrame(
        target: bucket.target,
        filter: bucket.filter,
        exposureSecs: exposureSecs,
        accepted: event.accepted,
      );
      while (_countedByPath.length > _countedFramesKept) {
        _countedByPath.remove(_countedByPath.keys.first);
      }
    }
    showPreview(
      previewSettingsFor(capture, capture.exposureSecs ?? 0.0),
      filePath: path == null || path.isEmpty ? null : path,
    );
    final frame = event.frame;
    if (frame == null) return;
    _graded[frame] = (accepted: event.accepted, capture: capture);
  }

  /// Consume the held verdict for [frame]; false when the frame was never
  /// graded and still needs counting.
  bool takeVerdict(int frame) => _graded.remove(frame) != null;

  /// Count one frame into the run's per-target, per-filter vitals; returns
  /// the target and filter it was counted under.
  ({String target, String filter}) recordRunFrame({
    required double exposureSecs,
    required bool accepted,
    String? filter,
  }) {
    final resolvedFilter = (filter != null && filter.isNotEmpty)
        ? filter
        : activeFilter();
    final bucket = (
      target: _activeTargetName(),
      filter: (resolvedFilter != null && resolvedFilter.isNotEmpty)
          ? resolvedFilter
          : 'Unknown',
    );
    _stats.update((stats) {
      stats.recordFrame(
        target: bucket.target,
        filter: bucket.filter,
        exposureSecs: exposureSecs,
        accepted: accepted,
      );
    });
    return bucket;
  }

  /// Apply the frame watch's assessment of a saved frame: an excluded frame
  /// that was counted as accepted moves to the rejected count in the run
  /// stats and the session (its time stops counting as integration), the
  /// frame's guide RMS joins the session average, and the frame's row gets
  /// its solve, sky background, guide RMS and exclusion. The row update waits
  /// for the row's own insert; a frame with no row is logged, never dropped
  /// silently.
  void recordAssessment(FrameAssessed event) {
    final path = event.savePath;
    if (path == null || path.isEmpty) {
      _logger.warning(
        'Frame assessment arrived without a save path; its solve, guide RMS '
        'and exclusion were not recorded.',
        source: 'SequenceExecutor',
      );
      return;
    }

    final session = _ref.read(sessionStateProvider.notifier);
    final exclusion = event.isExcluded ? event.exclusionReason : null;
    if (exclusion != null) {
      final counted = _countedByPath.remove(path);
      if (counted != null && counted.accepted) {
        _stats.update(
          (stats) => stats.reclassifyAsRejected(
            target: counted.target,
            filter: counted.filter,
            exposureSecs: counted.exposureSecs,
          ),
        );
        session.excludeAcceptedFrame(exposureTime: counted.exposureSecs);
      }
    }
    final rms = event.guideRmsTotal;
    if (rms != null && (event.guideRmsSamples ?? 1) > 0) {
      session.recordFrameGuidingRms(rms);
    }

    // Captured before the await: the update outlives the handler.
    final logger = _logger;
    final dao = _ref.read(imagesDaoProvider);
    final tracker = _ref.read(frameRegistrationTrackerProvider);
    final update = () async {
      try {
        await tracker.settled(path);
        final row = await dao.getLatestImageByFilePath(path);
        if (row == null) {
          logger.warning(
            'Frame assessment for $path matched no recorded frame; its solve, '
            'guide RMS and exclusion were not saved.',
            source: 'SequenceExecutor',
          );
          return;
        }
        final ra = event.solvedRaDeg;
        final dec = event.solvedDecDeg;
        final scale = event.solvedPixelScale;
        if (event.plateSolved && ra != null && dec != null && scale != null) {
          await writeFrameSolveToRow(
            dao,
            path,
            raDegrees: ra,
            decDegrees: dec,
            rotationDegrees: event.solvedRotationDeg ?? 0.0,
            pixelScaleArcsec: scale,
          );
        }
        await dao.applyFrameAssessment(
          row.id,
          background: event.backgroundAdu,
          guidingRmsTotal: rms,
          pierSide: event.pierSide,
          exclusionReason: exclusion,
        );
        if (exclusion != null && !_isDisposed()) {
          _ref
              .read(sessionImagesProvider.notifier)
              .removeImage(row.id.toString());
        }
      } catch (e) {
        logger.warning(
          'Could not record the frame assessment of $path: $e',
          source: 'SequenceExecutor',
        );
      } finally {
        _science.assessed(path, event);
      }
    }();
    _inFlight.add(update);
    unawaited(update.whenComplete(() => _inFlight.remove(update)));
  }

  /// The filter the run is exposing through: the Change Filter instruction's
  /// name, else the wheel's. One resolution for the row and the stats, so a
  /// frame never gets two recorded filters.
  String? activeFilter() =>
      _ref.read(sequenceProgressProvider).currentFilter ??
      _ref.read(filterWheelStateProvider).currentFilterName;

  /// The target being imaged, for the stats breakdown: the name a target
  /// event gave, else the executing node's enclosing target, else the
  /// sequence's own name.
  String _activeTargetName() {
    final progress = _ref.read(sequenceProgressProvider);
    final fromEvent = progress.currentTarget;
    if (fromEvent != null && fromEvent.isNotEmpty) return fromEvent;

    final sequence = _ref.read(currentSequenceProvider);
    final nodeId = progress.currentNodeId;
    if (sequence != null && nodeId != null) {
      final name = enclosingTargetHeader(sequence, nodeId)?.targetName;
      if (name != null && name.isNotEmpty) return name;
    }
    return sequence?.name ?? 'Sequence';
  }

  /// The settings stamped on a frame's preview: the camera's reported values,
  /// else the producing node's configuration (a host with no capture
  /// payload), never literals.
  ExposureSettings previewSettingsFor(
    FrameCapture? capture,
    double durationSecs,
  ) {
    final filter = activeFilter();
    final sequence = _ref.read(currentSequenceProvider);
    final nodeId = _ref.read(sequenceProgressProvider).currentNodeId;
    final attribution = (sequence == null || nodeId == null)
        ? const FrameAttribution()
        : resolveFrameAttribution(sequence, nodeId, currentFilter: filter);
    return ExposureSettings(
      exposureTime:
          capture?.exposureSecs ?? attribution.exposureSecs ?? durationSecs,
      gain: capture?.gain ?? attribution.gain ?? 0,
      offset: capture?.offset ?? attribution.offset ?? 0,
      binningX: capture?.binX ?? attribution.binX,
      binningY: capture?.binY ?? attribution.binY,
      filter: filter,
      frameType: switch (capture?.frameType?.toLowerCase() ??
          attribution.frameType) {
        'dark' => FrameType.dark,
        'flat' => FrameType.flat,
        'bias' => FrameType.bias,
        'darkflat' => FrameType.darkFlat,
        'snapshot' => FrameType.snapshot,
        _ => FrameType.light,
      },
    );
  }

  /// Fetch the camera's last image and publish it as the live preview.
  /// Fire-and-forget: a failed preview never affects the run.
  void showPreview(ExposureSettings settings, {String? filePath}) {
    Future(() async {
      try {
        final cameraDeviceId = _ref.read(cameraStateProvider).deviceId;
        if (cameraDeviceId == null || cameraDeviceId.isEmpty) {
          _logger.debug(
            'No camera device ID available, skipping image fetch',
            source: 'SequenceExecutor',
          );
          return;
        }
        final capturedImage = await _backend.cameraGetLastImage(cameraDeviceId);
        if (capturedImage == null) {
          _logger.debug(
            'No image data available from camera',
            source: 'SequenceExecutor',
          );
          return;
        }
        final imageData = capturedImageDataFromResult(
          capturedImage: capturedImage,
          capturedAt: DateTime.now(),
          settings: settings,
          filePath: filePath,
        );
        _ref
            .read(capturePreviewPublisherProvider)
            .publish(_ref, imageData, cameraDeviceId);
      } catch (e) {
        _logger.warning(
          'Failed to fetch sequence image for display: $e',
          source: 'SequenceExecutor',
        );
      }
    });
  }

  /// Write [event]'s frame as a `captured_images` row tagged with its
  /// producing node, advance the session counters, and hand a light frame to
  /// the science pipeline (see [RunFrameScience]). Fire-and-forget;
  /// failures are logged and never block the run. A frame with no producing
  /// node (a wizard capture) has nothing to hang a row off and is skipped.
  void register(FrameGraded event, {required String grade}) {
    final isAccepted = event.accepted;
    final nodeId = event.nodeId;
    if (nodeId == null || nodeId.isEmpty) return;
    final hfr = event.hfr;
    final eccentricity = event.eccentricity;
    final starCount = event.starCount;
    // HFR and star count only (the event carries no background or noise);
    // NaN, stored as NULL, when the frame reported neither.
    final rawQualityScore = computeFrameQualityScore(
      hfr: hfr,
      starCount: starCount,
    );
    final qualityScore = rawQualityScore.isNaN ? null : rawQualityScore;
    // The capture truth the FITS header was written from, so the row and the
    // file agree about the same exposure.
    final capture = event.capture;
    // An empty path keeps the "no thumbnail yet" tile rather than dropping the
    // row.
    final filePath = event.filePath ?? '';
    final fileName = filePath.isEmpty ? '' : p.basename(filePath);
    final rejectionReason = switch (event) {
      FrameRejected(:final reason) => reason,
      FrameAccepted() => null,
    };
    final filter = activeFilter();
    final runIdString = _ref.read(currentRunIdProvider)?.toString();
    // No open session row means a NULL column, not a dangling id.
    final dbSessionId = _ref.read(sessionStateProvider).dbSessionId;
    final sessionId = (dbSessionId != null && dbSessionId > 0)
        ? dbSessionId
        : null;
    final dao = _ref.read(imagesDaoProvider);
    final sidecarService = _ref.read(thumbnailSidecarServiceProvider);

    // Resolved now, from the tree as it was when the frame was produced. The
    // `capture.x ?? attribution.x` fallbacks serve only a client paired with
    // an appliance older than the capture payload; on the FFI path the
    // capture value is the stronger source. The target id is a `targets.id`
    // resolved here, never the event's own `target_id` (a node id).
    final loadedSequence = _ref.read(currentSequenceProvider);
    final attribution = loadedSequence == null
        ? const FrameAttribution()
        : resolveFrameAttribution(
            loadedSequence,
            nodeId,
            currentFilter: filter,
          );
    final targetId =
        attribution.targetId ??
        (loadedSequence == null
            ? null
            : _targets.targetIdFor(loadedSequence, nodeId));
    // The shutter time the camera reported, bounded natively against the
    // commanded duration.
    final exposureSecs = capture.exposureSecs ?? attribution.exposureSecs;
    if (exposureSecs == null) {
      _logger.warning(
        'Sequence frame from node $nodeId has no resolvable exposure duration '
        '(producing node is not an ExposureNode); recording 0s rather than a '
        'fabricated value.',
        source: 'SequenceExecutor',
      );
    }

    // The frame is on disk whether or not the insert below succeeds, so the
    // session counters move now. A rejected frame counts as a capture but not
    // toward integration or the HFR average (recordExposureComplete's rule).
    _ref
        .read(sessionStateProvider.notifier)
        .recordExposureComplete(
          exposureTime: exposureSecs ?? 0.0,
          hfr: hfr,
          accepted: isAccepted,
        );

    // Captured before the await: the insert outlives the handler, and reading
    // a provider from a disposed container throws.
    final logger = _logger;
    final frameType = capture.frameType?.toLowerCase() ?? attribution.frameType;
    final darkLibrary = frameType == 'dark' || frameType == 'bias'
        ? _ref.read(darkLibraryServiceProvider)
        : null;
    // A linked client has no access to the host's files; the host processes
    // its own frames.
    final scienceAssessment =
        _backend is! NetworkBackend &&
            RunFrameScience.appliesTo(frameType, filePath)
        ? _science.expectAssessment(filePath, exposureSecs)
        : null;
    final science = scienceAssessment == null
        ? null
        : _ref.read(scienceProcessingServiceProvider);
    final registration = () async {
      try {
        final rowId = await dao.insertSequenceFrame(
          filePath: filePath,
          fileName: fileName,
          fileFormat: filePath.toLowerCase().endsWith('.xisf')
              ? 'xisf'
              : 'fits',
          exposureDuration: exposureSecs ?? 0.0,
          targetId: targetId,
          capturedAt: DateTime.now(),
          isAccepted: isAccepted,
          producingNodeId: nodeId,
          producingRunId: runIdString,
          runtimeGrade: grade,
          rejectionReason: rejectionReason,
          filter: filter,
          // FITS IMAGETYP, in the images DB's lowercase spelling.
          frameType: frameType,
          gain: capture.gain ?? attribution.gain,
          offset: capture.offset ?? attribution.offset,
          binX: capture.binX ?? attribution.binX,
          binY: capture.binY ?? attribution.binY,
          sensorTemp: capture.sensorTempC,
          coolerPower: capture.coolerPowerPercent,
          mountRa: capture.mountRaHours,
          mountDec: capture.mountDecDegrees,
          mountAltitude: capture.mountAltitudeDeg,
          mountAzimuth: capture.mountAzimuthDeg,
          pierSide: capture.pierSide,
          focuserPosition: capture.focuserPosition,
          focuserTemp: capture.focuserTemperatureC,
          rotatorAngle: capture.rotatorAngleDeg,
          sessionId: sessionId,
          hfr: hfr,
          starCount: starCount,
          eccentricity: eccentricity,
          qualityScore: qualityScore,
          logger: logger,
          sidecarService: sidecarService,
        );
        if (science != null && scienceAssessment != null) {
          unawaited(
            _science.queue(
              science: science,
              assessment: scienceAssessment,
              filePath: filePath,
              capturedImageId: rowId,
              sessionId: sessionId,
            ),
          );
        }
        // The live "recent frames" list shows the row as persisted. Accepted
        // frames only: that strip has no way to mark a reject.
        if (darkLibrary != null) {
          try {
            await darkLibrary.addDarkFrame(
              filePath: filePath,
              exposureTime: exposureSecs ?? 0.0,
              frameType: frameType,
              temperature: capture.sensorTempC,
              gain: capture.gain ?? attribution.gain ?? 0,
              offset: capture.offset ?? attribution.offset ?? 0,
              binX: capture.binX ?? attribution.binX,
              binY: capture.binY ?? attribution.binY,
            );
          } catch (e) {
            logger.warning(
              'Recorded $frameType frame $filePath but could not add it to the '
              'dark library: $e',
              source: 'SequenceExecutor',
            );
          }
        }
        if (isAccepted && !_isDisposed()) {
          try {
            final row = await dao.getImageById(rowId);
            if (row != null && !_isDisposed()) {
              _ref
                  .read(sessionImagesProvider.notifier)
                  .addImage(capturedImageFromDbRow(row));
            }
          } catch (e) {
            logger.warning(
              'Registered sequence frame $rowId but could not add it to the '
              'live session list: $e',
              source: 'SequenceExecutor',
            );
          }
        }
        // Credit an accepted frame with a target and filter to its durable
        // campaign counter. Bookkeeping only: it never feeds the scheduler's
        // goal checks or the frame's attribution.
        if (isAccepted &&
            targetId != null &&
            filter != null &&
            filter.isNotEmpty) {
          if (_isDisposed()) return;
          try {
            await _ref
                .read(campaignsDaoProvider)
                .recordAccepted(
                  targetId: targetId,
                  filter: filter,
                  capturedAt: DateTime.now(),
                );
          } catch (e) {
            logger.warning(
              'Phase B: failed to credit campaign for target '
              '$targetId filter $filter: $e',
              source: 'SequenceExecutor',
            );
          }
        }
      } catch (e) {
        logger.warning(
          'Thumbnail: failed to register sequence frame for '
          'node $nodeId ($grade): $e',
          source: 'SequenceExecutor',
        );
      }
    }();
    _inFlight.add(registration);
    _ref.read(frameRegistrationTrackerProvider).track(filePath, registration);
    unawaited(registration.whenComplete(() => _inFlight.remove(registration)));
  }
}

/// The bucket a graded frame was counted in.
class _CountedFrame {
  const _CountedFrame({
    required this.target,
    required this.filter,
    required this.exposureSecs,
    required this.accepted,
  });

  final String target;
  final String filter;
  final double exposureSecs;
  final bool accepted;
}
