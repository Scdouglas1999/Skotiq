// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of '../weather_safety_provider.dart';

/// Remote (companion) safety-status polling for [WeatherSafetyNotifier].
extension _WeatherSafetyRemote on WeatherSafetyNotifier {
  void _startRemoteStatusPolling() {
    unawaited(_refreshRemoteStatus());
    _remoteStatusTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_refreshRemoteStatus());
    });
  }

  Future<void> _refreshRemoteStatus() async {
    if (_remoteFetchInFlight || !mounted) return;
    final remote = _ref.read(linkedHostWeatherProvider);
    final link = _ref.read(linkedHostLinkProvider);
    if (remote == null || link == null) return;
    // isAuthTokenRejected: terminal credentials — polling can only 403, so
    // don't. But the last verdict fetched is no longer known to hold, and
    // leaving it on show would keep a stale "Safe" on the card all night.
    // Replace it once with the same unavailable state a failed poll writes.
    if (link.isAuthTokenRejected) {
      if (state.failModeWarning != _authRejectedSafetyWarning) {
        state = WeatherSafetyState.initial().copyWith(
          failModeWarning: _authRejectedSafetyWarning,
          lastEvaluation: DateTime.now(),
          hostVerdictUnavailable: true,
        );
      }
      return;
    }
    _remoteFetchInFlight = true;
    try {
      final response = await remote.getSafetyStatus();
      if (!mounted) return;
      state = WeatherSafetyState.fromJson(response);
    } catch (error) {
      if (!mounted) return;
      state = WeatherSafetyState.initial().copyWith(
        failModeWarning:
            'Imaging host safety status unavailable: ${userFacingError(error)}',
        lastEvaluation: DateTime.now(),
        hostVerdictUnavailable: true,
      );
    } finally {
      _remoteFetchInFlight = false;
    }
  }
}

const _authRejectedSafetyWarning =
    'Imaging host safety status unavailable: the host rejected this '
    "device's access token";
