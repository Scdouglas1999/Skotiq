import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../command_correlator.dart';
import '../display_buffer_jpeg.dart';
import '../job_manager.dart';
import '../response_helpers.dart';
import '../utils/device_type_parser.dart';
import '../validation.dart';
import 'frame_measurement_headers.dart';

part 'device_handlers/connection_lifecycle.dart';
part 'device_handlers/camera_handlers.dart';
part 'device_handlers/mount_handlers.dart';
part 'device_handlers/focuser_handlers.dart';
part 'device_handlers/filter_wheel_handlers.dart';
part 'device_handlers/rotator_handlers.dart';
part 'device_handlers/helpers.dart';

/// MIME-style `Accept` header value that opts the caller into the
/// pre-synchronous response shape for autofocus / plate-solve /
/// center-on-target / polar-alignment. New clients should not send this;
/// the audit's spec keeps the legacy path so pinned mobile builds stay
/// functional during the rollout.
const String legacyBlockingAcceptType =
    'application/x.skotiq.legacy-blocking';

/// True when the request's `Accept` header explicitly opts into the
/// legacy synchronous response shape.
bool requestPrefersLegacyBlocking(Request request) {
  final accept = request.headers['accept'] ?? '';
  if (accept.isEmpty) return false;
  // Accept may be a comma-separated list; do a case-insensitive contains
  // check against the documented opt-in type.
  return accept.toLowerCase().contains(legacyBlockingAcceptType);
}

/// Handlers for device control endpoints (camera, mount, focuser, filter wheel, rotator)
class DeviceHandlers {
  final ProviderContainer container;

  /// optional command correlator. When set, every action POST
  /// generates a UUID v4 commandId and includes it in the response. The
  /// later SkotiqEvent that completes the command picks the id back
  /// up via `correlatingCommandId`. Null in unit tests that don't care
  /// about correlation (those tests still validate the legacy response
  /// shape).
  final CommandCorrelator? commandCorrelator;

  /// optional job manager. When set, long-running endpoints
  /// (currently autofocus) return `{jobId, status: queued, commandId}`
  /// immediately and surface progress via the WS event stream. When null
  /// (unit tests / legacy callers), the handler falls back to the
  /// blocking response shape.
  final JobManager? jobManager;

  DeviceHandlers(this.container, {this.commandCorrelator, this.jobManager});

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'DeviceHandlers');

  void _logWarning(String message) =>
      _logger.warning(message, source: 'DeviceHandlers');
}
