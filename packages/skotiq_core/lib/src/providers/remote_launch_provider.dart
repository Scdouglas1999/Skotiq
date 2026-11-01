import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_provider.dart';
import 'profiles_provider.dart' show equipmentProfilesProvider;
import 'settings_provider.dart' show appSettingsProvider;

/// The imaging host this process was launched to drive (`--remote-host` or
/// `SKOTIQ_REMOTE_HOST`). Null for a process that owns its own hardware.
class RemoteLaunchTarget {
  final String host;
  final int port;
  final String? token;
  final String scheme;

  const RemoteLaunchTarget({
    required this.host,
    required this.port,
    this.token,
    this.scheme = 'http',
  });

  /// How the host is named to the user.
  String get label => '$host:$port';
}

/// Overridden by the desktop entry point when it was launched as a companion.
final remoteLaunchTargetProvider = Provider<RemoteLaunchTarget?>((_) => null);

/// Why a companion could not open its session with the imaging host.
enum RemoteLaunchFailure {
  /// The host did not answer (wrong address, host off or busy, network down).
  unreachable,

  /// The host answered and refused this companion's access token.
  tokenRejected,

  /// The host answered but the connection could not be completed, for
  /// example because the two versions are incompatible.
  refused,
}

enum RemoteLaunchPhase { idle, connecting, connected, failed }

class RemoteLaunchStatus {
  final RemoteLaunchPhase phase;
  final RemoteLaunchFailure? failure;
  final String? detail;

  const RemoteLaunchStatus._(this.phase, {this.failure, this.detail});

  const RemoteLaunchStatus.idle() : this._(RemoteLaunchPhase.idle);
  const RemoteLaunchStatus.connecting() : this._(RemoteLaunchPhase.connecting);
  const RemoteLaunchStatus.connected() : this._(RemoteLaunchPhase.connected);
  const RemoteLaunchStatus.failed(RemoteLaunchFailure failure, String detail)
    : this._(RemoteLaunchPhase.failed, failure: failure, detail: detail);

  bool get isFailed => phase == RemoteLaunchPhase.failed;
}

/// One plain sentence naming the host and what went wrong.
String remoteLaunchFailureMessage(
  RemoteLaunchTarget target,
  RemoteLaunchFailure failure,
) {
  switch (failure) {
    case RemoteLaunchFailure.unreachable:
      return "Can't reach the imaging host at ${target.label}.";
    case RemoteLaunchFailure.tokenRejected:
      return 'The imaging host at ${target.label} rejected the access token.';
    case RemoteLaunchFailure.refused:
      return 'The imaging host at ${target.label} refused the connection.';
  }
}

/// Classify a failed companion connect. [tokenRejected] is the backend's own
/// record that the host refused the token; otherwise a transport failure means
/// the host never answered.
RemoteLaunchFailure classifyRemoteLaunchFailure(
  Object? error, {
  required bool tokenRejected,
}) {
  if (tokenRejected) return RemoteLaunchFailure.tokenRejected;
  final text = error?.toString().toLowerCase() ?? '';
  if (text.contains('invalid authentication token') ||
      text.contains('http 401') ||
      text.contains('http 403')) {
    return RemoteLaunchFailure.tokenRejected;
  }
  if (error is SocketException ||
      error is TimeoutException ||
      error is HttpException ||
      text.contains('connection refused') ||
      text.contains('timed out') ||
      text.contains('timeout') ||
      text.contains('failed host lookup') ||
      text.contains('no route to host') ||
      text.contains('state=disconnected') ||
      text.contains('state=connecting') ||
      text.contains('state=reconnecting')) {
    return RemoteLaunchFailure.unreachable;
  }
  return RemoteLaunchFailure.refused;
}

/// Opens (and re-opens) a companion's session with its launch target and
/// records the outcome for the UI. An unreachable host is retried on its own
/// every [autoRetryInterval]; a rejected token is not, since retrying cannot
/// change the answer.
class RemoteLaunchStatusNotifier extends StateNotifier<RemoteLaunchStatus> {
  RemoteLaunchStatusNotifier(this._ref)
    : super(const RemoteLaunchStatus.idle());

  final Ref _ref;
  Timer? _retryTimer;
  Future<bool>? _inFlight;

  static const Duration autoRetryInterval = Duration(seconds: 20);

  /// Connect to the launch target. Returns true when the session is live.
  /// Never throws: the outcome is in [state].
  Future<bool> connect() {
    final running = _inFlight;
    if (running != null) return running;
    final future = _connect();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<bool> _connect() async {
    final target = _ref.read(remoteLaunchTargetProvider);
    if (target == null) return false;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (mounted) state = const RemoteLaunchStatus.connecting();
    final backends = _ref.read(backendProvider.notifier);
    try {
      await backends.connect(
        target.host,
        target.port,
        authToken: target.token,
        scheme: target.scheme,
      );
      // Host-backed values resolved while disconnected stay empty until
      // re-read against the live session.
      _ref.invalidate(appSettingsProvider);
      _ref.invalidate(equipmentProfilesProvider);
      if (mounted) state = const RemoteLaunchStatus.connected();
      return true;
    } catch (error) {
      final failure = classifyRemoteLaunchFailure(
        error,
        tokenRejected: backends.lastConnectTokenRejected,
      );
      if (!mounted) return false;
      state = RemoteLaunchStatus.failed(failure, error.toString());
      if (failure != RemoteLaunchFailure.tokenRejected) {
        _retryTimer = Timer(autoRetryInterval, () => unawaited(connect()));
      }
      return false;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }
}

final remoteLaunchStatusProvider =
    StateNotifierProvider<RemoteLaunchStatusNotifier, RemoteLaunchStatus>(
      RemoteLaunchStatusNotifier.new,
    );
