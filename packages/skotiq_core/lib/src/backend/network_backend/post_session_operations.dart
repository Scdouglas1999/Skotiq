part of '../network_backend.dart';

/// Remote (REST) client for the host's **post-session integration / finishing**
/// control surface (`/api/post-session/*`).
///
/// This is the "review and integrate last night's data" workflow run over the
/// wire: a tablet hands the host the on-disk paths of the subs / masters and the
/// host's Rust pipeline does the compute. No pixel data crosses the wire — the
/// request bodies are exactly the native JSON arg envelopes the host-side
/// `BridgePostSessionSeam` would have passed to the FFI directly, and the
/// results are the identical JSON envelopes the FFI returns. The
/// [PostSessionSeam] result classes (`IntegrateSessionResult`, …) decode those
/// maps verbatim, so a remote run is byte-for-byte equivalent to a local one.
///
/// Every op is long-running, so the host runs it as a [JobManager] job: the POST
/// returns `{jobId}` and these methods await the job to its terminal state via
/// the shared [awaitJobCompletion] helper, then surface the job's `result`
/// envelope (or throw on a failed / cancelled job). Per-op timeouts are tuned to
/// the work: integration / drizzle can run for many minutes, the analytic
/// predictor is quick.
///
/// Mosaic stitching is intentionally NOT part of this surface.
mixin _NetworkBackendPostSessionOperations on _NetworkBackendTransport {
  /// Read the host-owned automatic post-session integration preference.
  Future<bool> getAutoIntegrationEnabled() async {
    final response = await _get('post-session/settings');
    final enabled = response['autoIntegrate'];
    if (enabled is! bool) {
      throw const ValidationException(
        message: 'post-session settings returned a non-boolean autoIntegrate',
        userMessage: 'The host returned invalid post-session settings.',
      );
    }
    return enabled;
  }

  /// Change the host-owned automatic post-session integration preference.
  Future<void> setAutoIntegrationEnabled(bool enabled) async {
    await _post('post-session/settings', {'autoIntegrate': enabled});
  }

  /// Implemented by [_NetworkBackendRemoteOperations]; declared here so this
  /// mixin can await the job without depending on the concrete class.
  Future<RemoteJob> awaitJobCompletion(
    String jobId, {
    Duration timeout,
    Duration pollInterval,
  });

  /// POST a post-session op, await its job, and return the result envelope.
  ///
  /// Throws an [IoException] when the job ends `failed` / `cancelled` (the
  /// host's structured error, if any, is folded into the message), or a
  /// [ValidationException] when the terminal job carries no result map (a
  /// server contract violation).
  Future<Map<String, dynamic>> _runPostSessionJob(
    String endpoint,
    Map<String, dynamic> args, {
    required Duration timeout,
  }) async {
    final start = await _post(endpoint, args);
    final jobId = start['jobId'] as String?;
    if (jobId == null || jobId.isEmpty) {
      throw ValidationException(
        message: 'post-session $endpoint did not return a jobId',
        userMessage: 'The host did not accept the operation.',
      );
    }
    final job = await awaitJobCompletion(jobId, timeout: timeout);
    if (job.state != 'succeeded') {
      final detail = job.error?['message'] ?? job.error?['code'] ?? job.state;
      throw IoException(
        message:
            'post-session $endpoint job ${job.jobId} ended ${job.state}: '
            '$detail',
        userMessage: 'The operation failed on the host.',
      );
    }
    final result = job.result;
    if (result == null) {
      throw ValidationException(
        message:
            'post-session $endpoint job ${job.jobId} succeeded with no result',
        userMessage: 'The host returned an empty result.',
      );
    }
    return result;
  }

  /// A long compute ceiling for integration / drizzle / accumulate / finishing
  /// passes — these can fold dozens of full-frame subs.
  static const Duration _postSessionLongTimeout = Duration(minutes: 30);

  /// A shorter ceiling for the quick analytic / detection passes.
  static const Duration _postSessionQuickTimeout = Duration(minutes: 5);

  /// Integrate a session's subs into a linear FITS master on the host. [args] is
  /// the `IntegrateSessionArgs` JSON shape (host paths). Returns the
  /// `IntegrateSessionResult` envelope.
  Future<Map<String, dynamic>> postSessionIntegrate(Map<String, dynamic> args) {
    return _runPostSessionJob(
      'post-session/integrate',
      args,
      timeout: _postSessionLongTimeout,
    );
  }

  /// Drizzle-integrate accepted subs onto a scaled grid on the host. [args] is
  /// the `DrizzleIntegrateArgs` JSON shape (host paths). Returns the drizzle
  /// result envelope (`{outputPath, outWidth, outHeight, channels, …}`).
  Future<Map<String, dynamic>> postSessionDrizzleIntegrate(
    Map<String, dynamic> args,
  ) {
    return _runPostSessionJob(
      'post-session/drizzle',
      args,
      timeout: _postSessionLongTimeout,
    );
  }

  /// Predict the marginal-SNR integration curve + keep/cull recommendation on
  /// the host. [args] is `{ qualities, weights, exposuresS, optimizer? }`.
  /// Returns the `IntegrationCurve` envelope.
  Future<Map<String, dynamic>> postSessionAnalyzeNight(
    Map<String, dynamic> args,
  ) {
    return _runPostSessionJob(
      'post-session/analyze-night',
      args,
      timeout: _postSessionQuickTimeout,
    );
  }

  /// Build a unit-mean master flat from raw flats on the host. [args] is the
  /// `BuildMasterFlatArgs` JSON shape (host paths). Returns the
  /// `BuildMasterFlatResult` envelope.
  Future<Map<String, dynamic>> postSessionBuildMasterFlat(
    Map<String, dynamic> args,
  ) {
    return _runPostSessionJob(
      'post-session/build-master-flat',
      args,
      timeout: _postSessionLongTimeout,
    );
  }

  /// Solve + apply a per-channel white balance on the host. [args] is
  /// `{ inputFits, outputFits, channels, whiteRefBv?, matchedStars }` (host
  /// paths). Returns the `ColorCalibrationResult` envelope.
  Future<Map<String, dynamic>> postSessionColorCalibrate(
    Map<String, dynamic> args,
  ) {
    return _runPostSessionJob(
      'post-session/color-calibrate',
      args,
      timeout: _postSessionLongTimeout,
    );
  }

  /// Detect + measure stars (per-channel aperture flux) on the host. [args] is
  /// `{ inputFits, maxStars?, aperture? }` (host path). Returns the
  /// `StarPhotometryResult` envelope.
  Future<Map<String, dynamic>> postSessionDetectStars(
    Map<String, dynamic> args,
  ) {
    return _runPostSessionJob(
      'post-session/detect-stars',
      args,
      timeout: _postSessionQuickTimeout,
    );
  }

  /// Fit + subtract a low-order background model on the host. [args] is
  /// `{ inputFits, outputFits, config? }` (host paths). Returns the
  /// `{outputPath}` envelope.
  Future<Map<String, dynamic>> postSessionExtractBackground(
    Map<String, dynamic> args,
  ) {
    return _runPostSessionJob(
      'post-session/extract-background',
      args,
      timeout: _postSessionLongTimeout,
    );
  }

  /// Linearly combine single-channel narrowband masters into an RGB composite
  /// on the host. [args] is the `CombineChannelsArgs` JSON shape (host paths).
  /// Returns the `{outputPath}` envelope.
  Future<Map<String, dynamic>> postSessionCombineChannels(
    Map<String, dynamic> args,
  ) {
    return _runPostSessionJob(
      'post-session/combine-channels',
      args,
      timeout: _postSessionLongTimeout,
    );
  }

  /// Drive the multi-night accumulating master on the host. [args] carries an
  /// `op` of `create` / `add` / `finalize` / `info` plus that op's fields (host
  /// paths). Returns the `MasterAccumulateResult` envelope.
  Future<Map<String, dynamic>> postSessionMasterAccumulate(
    Map<String, dynamic> args,
  ) {
    return _runPostSessionJob(
      'post-session/master-accumulate',
      args,
      timeout: _postSessionLongTimeout,
    );
  }
}
