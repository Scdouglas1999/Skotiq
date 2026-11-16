part of '../network_backend.dart';

/// Post-session processing passes run by a linked imaging host on its own
/// files.
final class HostPostSession {
  HostPostSession(this._host);

  final NetworkBackend _host;

  /// Predict the marginal-SNR integration curve + keep/cull recommendation on
  /// the host. [args] is `{ qualities, weights, exposuresS, optimizer? }`.
  /// Returns the `IntegrationCurve` envelope.
  Future<Map<String, dynamic>> postSessionAnalyzeNight(
    Map<String, dynamic> args,
  ) {
    return _host._runPostSessionJob(
      PostSessionApi.analyzeNight,
      args,
      timeout: _NetworkBackendPostSessionOperations._postSessionQuickTimeout,
    );
  }

  /// Build a unit-mean master flat from raw flats on the host. [args] is the
  /// `BuildMasterFlatArgs` JSON shape (host paths). Returns the
  /// `BuildMasterFlatResult` envelope.
  Future<Map<String, dynamic>> postSessionBuildMasterFlat(
    Map<String, dynamic> args,
  ) {
    return _host._runPostSessionJob(
      PostSessionApi.buildMasterFlat,
      args,
      timeout: _NetworkBackendPostSessionOperations._postSessionLongTimeout,
    );
  }

  /// Solve + apply a per-channel white balance on the host. [args] is
  /// `{ inputFits, outputFits, channels, whiteRefBv?, matchedStars }` (host
  /// paths). Returns the `ColorCalibrationResult` envelope.
  Future<Map<String, dynamic>> postSessionColorCalibrate(
    Map<String, dynamic> args,
  ) {
    return _host._runPostSessionJob(
      PostSessionApi.colorCalibrate,
      args,
      timeout: _NetworkBackendPostSessionOperations._postSessionLongTimeout,
    );
  }

  /// Detect + measure stars (per-channel aperture flux) on the host. [args] is
  /// `{ inputFits, maxStars?, aperture? }` (host path). Returns the
  /// `StarPhotometryResult` envelope.
  Future<Map<String, dynamic>> postSessionDetectStars(
    Map<String, dynamic> args,
  ) {
    return _host._runPostSessionJob(
      PostSessionApi.detectStars,
      args,
      timeout: _NetworkBackendPostSessionOperations._postSessionQuickTimeout,
    );
  }

  /// Drizzle-integrate accepted subs onto a scaled grid on the host. [args] is
  /// the `DrizzleIntegrateArgs` JSON shape (host paths). Returns the drizzle
  /// result envelope (`{outputPath, outWidth, outHeight, channels, …}`).
  Future<Map<String, dynamic>> postSessionDrizzleIntegrate(
    Map<String, dynamic> args,
  ) {
    return _host._runPostSessionJob(
      PostSessionApi.drizzleIntegrate,
      args,
      timeout: _NetworkBackendPostSessionOperations._postSessionLongTimeout,
    );
  }

  /// Fit + subtract a low-order background model on the host. [args] is
  /// `{ inputFits, outputFits, config? }` (host paths). Returns the
  /// `{outputPath}` envelope.
  Future<Map<String, dynamic>> postSessionExtractBackground(
    Map<String, dynamic> args,
  ) {
    return _host._runPostSessionJob(
      PostSessionApi.extractBackground,
      args,
      timeout: _NetworkBackendPostSessionOperations._postSessionLongTimeout,
    );
  }

  /// Integrate a session's subs into a linear FITS master on the host. [args] is
  /// the `IntegrateSessionArgs` JSON shape (host paths). Returns the
  /// `IntegrateSessionResult` envelope.
  Future<Map<String, dynamic>> postSessionIntegrate(Map<String, dynamic> args) {
    return _host._runPostSessionJob(
      PostSessionApi.integrateSession,
      args,
      timeout: _NetworkBackendPostSessionOperations._postSessionLongTimeout,
    );
  }

  /// Drive the multi-night accumulating master on the host. [args] carries an
  /// `op` of `create` / `add` / `finalize` / `info` plus that op's fields (host
  /// paths). Returns the `MasterAccumulateResult` envelope.
  Future<Map<String, dynamic>> postSessionMasterAccumulate(
    Map<String, dynamic> args,
  ) {
    return _host._runPostSessionJob(
      PostSessionApi.masterAccumulate,
      args,
      timeout: _NetworkBackendPostSessionOperations._postSessionLongTimeout,
    );
  }

  /// Read the host-owned automatic post-session integration preference.
  Future<bool> getAutoIntegrationEnabled() async {
    final response = await _host._get(PostSessionApi.getSettings);
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
    await _host._post(
      PostSessionApi.updateSettings,
      body: {'autoIntegrate': enabled},
    );
  }
}
