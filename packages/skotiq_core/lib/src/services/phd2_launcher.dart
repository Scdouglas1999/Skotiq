import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_api;

import '../providers/ui_notification_provider.dart';
import 'phd2_status_poll.dart';

/// Auto-launches PHD2 on the local machine and waits for its socket to
/// come up.
///
/// PHD2 is an external program; the user typically configures the path
/// in Settings → PHD2 and expects "Connect Guider" to start the process
/// when it is not already running. This launcher encapsulates that
/// concern so DeviceService does not have to reach into `dart:io` or
/// the FRB bridge for process spawning.
///
/// Three branches:
///   1. Socket already open → no-op.
///   2. Configured path → spawn that exe (detached).
///   3. No configured path → ask Rust to auto-discover via `apiLaunchPhd2`.
///
/// After spawning, poll the port for [launchTimeout] before giving up.
class Phd2Launcher {
  Phd2Launcher({
    required Ref ref,
    Duration launchTimeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 250),
  }) : _ref = ref,
       _launchTimeout = launchTimeout,
       _pollInterval = pollInterval;

  final Ref _ref;
  final Duration _launchTimeout;
  final Duration _pollInterval;

  /// True when the configured host is the same machine (i.e. we should
  /// auto-spawn PHD2 ourselves rather than expecting it to be remote).
  bool isLocalHost(String host) {
    if (kIsWeb) return false;
    final normalized = host.trim().toLowerCase();
    return normalized.isEmpty ||
        normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1';
  }

  /// Ensure PHD2 is running on [host]:[port]. If a socket is already
  /// accepting connections we return immediately; otherwise we spawn
  /// [executablePath] (or trigger native auto-discovery if the path is
  /// blank) and wait up to the configured launch timeout for the port
  /// to open.
  Future<void> ensureRunning({
    required String executablePath,
    required String host,
    required int port,
  }) async {
    if (await _isPortOpen(host, port)) {
      return;
    }

    final notifications = _ref.read(uiNotificationProvider.notifier);
    final configuredPath = executablePath.trim();
    if (configuredPath.isNotEmpty) {
      final exe = File(configuredPath);
      if (!await exe.exists()) {
        throw FileSystemException(
          'PHD2 executable not found. Update Settings → PHD2 Guiding → '
          'PHD2 executable path or clear it to use automatic discovery.',
          configuredPath,
        );
      }

      notifications.showInfo(
        'PHD2 not running — launching $configuredPath...',
        title: 'PHD2',
        duration: const Duration(seconds: 5),
      );

      try {
        await Process.start(
          configuredPath,
          const <String>[],
          mode: ProcessStartMode.detached,
        );
      } on ProcessException catch (e) {
        throw ProcessException(
          configuredPath,
          const <String>[],
          'Failed to launch PHD2 (${e.message}). Check the configured '
          'PHD2 executable path.',
          e.errorCode,
        );
      }
    } else {
      notifications.showInfo(
        'PHD2 not running — searching for installed PHD2...',
        title: 'PHD2',
        duration: const Duration(seconds: 5),
      );

      try {
        await bridge_api.apiLaunchPhd2();
      } catch (_) {
        throw StateError(
          'PHD2 is not running and could not be launched automatically. '
          'Install PHD2 or set Settings → PHD2 Guiding → PHD2 executable '
          'path.',
        );
      }
    }

    // PHD2 typically takes 2-5s to begin accepting connections on cold
    // start; poll until the port opens or the deadline passes.
    final deadline = DateTime.now().add(_launchTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _isPortOpen(host, port)) {
        return;
      }
      await Future.delayed(_pollInterval);
    }

    throw TimeoutException(
      'PHD2 launched but did not open port $port on $host within '
      '${_launchTimeout.inSeconds} seconds. Verify PHD2 is configured '
      'to expose its server interface.',
      _launchTimeout,
    );
  }

  /// Check whether [host]:[port] is accepting TCP connections.
  Future<bool> _isPortOpen(String host, int port) async {
    final connectHost = resolvePhd2ConnectHost(host);
    try {
      final socket = await Socket.connect(
        connectHost,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
