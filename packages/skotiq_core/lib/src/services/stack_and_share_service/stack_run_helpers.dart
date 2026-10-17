part of '../stack_and_share_service.dart';

extension _StackRunHelpers on StackAndShareService {
  /// Start the stack from [frame], either via the in-memory calibrated data
  /// path (when [calibration] is provided) or the engine's native file loader.
  ///
  /// [stackingConfig] is the OSC-resolved engine config from
  /// [_resolveStackingConfig] — it carries the concrete sensor mode + Bayer
  /// pattern + demosaic quality the engine debayers with. For the calibrated
  /// data path the calibrated CFA mono plane is fed **unchanged**: the native
  /// stacker (component C3) debayers post-calibration, so debayering here would
  /// double-process the mosaic.
  Future<void> _startStack({
    required StackedFrameSelection frame,
    required LiveStackingConfig stackingConfig,
    required _CalibrationContext? calibration,
    required void Function(String file) emitCalibrating,
  }) async {
    if (calibration == null) {
      await _engine.startFromFile(
        referenceImagePath: frame.filePath,
        config: stackingConfig,
      );
      _ensureAuthority();
      return;
    }

    emitCalibrating(frame.filePath);
    final calibrated = await _loadCalibrated(frame, calibration);
    _ensureAuthority();
    await _engine.startFromData(
      width: calibrated.width,
      height: calibrated.height,
      data: calibrated.data,
      config: stackingConfig,
    );
    _ensureAuthority();
  }

  /// Add [frame] to the running stack, mirroring the data/file split used by
  /// [_startStack]. Returns the engine result so the caller can read the
  /// running stacked-frame count.
  Future<LiveStackingResult> _addStackFrame({
    required StackedFrameSelection frame,
    required _CalibrationContext? calibration,
  }) async {
    final service = _ref.read(liveStackingServiceProvider);
    if (calibration == null) {
      return service.addFrameFromFile(frame.filePath);
    }
    final calibrated = await _loadCalibrated(frame, calibration);
    _ensureAuthority();
    return service.addFrameFromData(
      width: calibrated.width,
      height: calibrated.height,
      data: calibrated.data,
    );
  }

  /// Total exposure time, in seconds, of the frames the engine actually
  /// integrated — summed over [integratedImageIds], not over everything the
  /// selector offered.
  ///
  /// [StackSelectionSummary.totalIntegrationSecs] is fixed before the engine
  /// runs, so it counts subs the stacker went on to refuse. Quoting it would
  /// overstate the integration on every stack that rejected anything — on the
  /// result screen, in the AstroBin sidecar, and on the Share Card the operator
  /// posts publicly. The claim has to describe the master that was built.
  ///
  /// Identical to the selection-wide total when nothing is rejected: both sum
  /// the same per-frame exposure over the same frames.
  double _integratedIntegrationSecs(
    StackSelectionSummary selection,
    Set<int> integratedImageIds,
  ) {
    var total = 0.0;
    for (final frame in selection.selected) {
      if (integratedImageIds.contains(frame.imageId)) {
        total += frame.exposureSecs;
      }
    }
    return total;
  }

  /// Mean HFR, in pixels, of the frames the engine actually integrated.
  ///
  /// The live stacker does not measure HFR, but every light already carries the
  /// focuser-grade HFR the capture pipeline measured (`captured_images.hfr`),
  /// which is the number an imager judges a stack by. Averaging those over
  /// [imageIds] is a statement about the subs in the integration — not a
  /// fabricated engine metric. Frames with no measured HFR are skipped rather
  /// than counted as zero; when none of them has one, the column stays NULL and
  /// the viewer's "Avg HFR" row correctly does not render.
  Future<double?> _averageIntegratedHfr({
    required int sessionId,
    required Set<int> imageIds,
  }) async {
    if (imageIds.isEmpty) return null;
    final images = await _imagesDao.getImagesForSession(sessionId);
    var sum = 0.0;
    var count = 0;
    for (final image in images) {
      if (!imageIds.contains(image.id)) continue;
      final hfr = image.hfr;
      if (hfr == null || !hfr.isFinite || hfr <= 0) continue;
      sum += hfr;
      count++;
    }
    if (count == 0) return null;
    return sum / count;
  }

  /// Resolve the OSC / colour intent for the run into a concrete engine config.
  ///
  /// The Stack-and-Share config carries a *sensor mode* (`auto` / `mono` /
  /// `osc`) and optional Bayer/demosaic knobs; the live stacker needs a single
  /// resolved [LiveStackingConfig] it can fix for the whole integration. This
  /// folds the share-loop OSC knobs into the wrapped stacking config (via
  /// [StackAndShareConfig.resolvedStackingConfig]) and then, for the OSC and
  /// auto modes, pins the concrete Bayer pattern:
  ///
  ///  * an explicit [StackAndShareConfig.bayerPatternOverride] always wins;
  ///  * otherwise the pattern is discovered from the connected camera's
  ///    [CameraCapabilities] (the live path) or, failing that, from the
  ///    reference frame's FITS `BAYERPAT` geometry exposed on
  ///    [LinearFrameData.bayerPattern] (the file path).
  ///
  /// For `sensorMode == 'osc'` an unresolvable pattern is a hard [StateError]:
  /// debayering with a guessed pattern would scramble the colour mosaic, so the
  /// run refuses rather than silently producing a wrong-colour stack. For
  /// `auto`, leaving the pattern null is fine — the native
  /// engine only debayers when the frame actually carries Bayer geometry and
  /// otherwise treats the frame as mono. For `mono`, no resolution is needed.
  Future<LiveStackingConfig> _resolveStackingConfig({
    required StackAndShareConfig config,
    required StackedFrameSelection reference,
  }) async {
    final resolved = config.resolvedStackingConfig;
    final mode = config.sensorMode.trim().toLowerCase();

    // Mono never debayers; an explicit override already pins the pattern.
    if (mode == 'mono' || resolved.bayerPattern != null) {
      return resolved;
    }

    // auto / osc with no explicit override: discover the pattern, preferring
    // the live camera's declared CFA, then the reference frame's FITS geometry.
    final pattern = await _discoverBayerPattern(reference);
    _ensureAuthority();

    if (pattern == null) {
      if (mode == 'osc') {
        throw StateError(
          'Stack-and-Share is configured for OSC (colour) stacking but no '
          'Bayer pattern could be resolved for reference frame '
          '"${reference.filePath}": the connected camera reports no CFA '
          'pattern and the frame carries no FITS BAYERPAT geometry. Set an '
          'explicit Bayer pattern or use auto/mono mode.',
        );
      }
      // auto with no pattern → treat as mono (engine will not debayer).
      return resolved;
    }

    return resolved.copyWith(bayerPattern: pattern);
  }

  /// The single filter of the stack, or null when the selection spans multiple
  /// filters (or none were recorded).
  ///
  /// An OSC (colour) stack is labelled `'OSC'` — a one-shot-colour integration
  /// has no single named filter (it captures R, G and B through the CFA at
  /// once), so reporting the (often `noFilterBucket`) capture filter would be
  /// misleading; `'OSC'` is the conventional AstroBin/acquisition label. A mono
  /// stack reports its one filter; a multi-filter selection reports null so the
  /// result is not mislabelled.
  String? _singleFilter(
    StackSelectionSummary selection, {
    required bool isColor,
  }) {
    if (isColor) return 'OSC';
    final named = selection.perFilterCounts.keys
        .where((f) => f != StackLightSelector.noFilterBucket)
        .toList(growable: false);
    if (named.length == 1) return named.first;
    return null;
  }
}
