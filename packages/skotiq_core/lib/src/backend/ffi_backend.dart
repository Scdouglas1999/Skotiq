import '../database/rows/frame_type_record.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../database/daos/images_dao.dart';
import '../database/database.dart';
import '../models/autofocus_progress.dart';
import '../models/depthlock/depthlock_models.dart';
import '../models/equipment/guider_for_move.dart';
import '../models/equipment_profile.dart';
import '../models/imaging/autofocus_request.dart';
import '../models/imaging/imaging_models.dart';
import '../models/mount_guard.dart';
import '../models/phd2_models.dart';
import '../models/plate_solver.dart';
import '../models/sequence/sequence_models.dart';
import '../models/site/location_settings.dart';
import 'phd2_probe.dart';
import 'phd2_status_poll.dart';
import '../models/imaging/fits_keyword_write.dart';
import 'stretch_pipeline_service.dart';
import 'thumbnail_sidecar_service.dart';
import '../utils/device_id.dart';
import '../errors/bridge_error_message.dart';
import '../errors/device_connect_exception.dart';
import 'skotiq_backend.dart';
import '../models/settings/app_settings.dart' as models;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../models/backend/device_capabilities_bridge.dart';
import '../models/backend/device_status_bridge.dart';
import '../errors/skotiq_error.dart' as dart_error;
import 'bridge_event_codec.dart';
import 'ip_geolocation.dart';
import '../models/backend/backend_types.dart';
import '../utils/logging_service.dart';

part 'ffi_backend/native_runtime.dart';
part 'ffi_backend/type_mappers.dart';
part 'ffi_backend/discovery_camera_operations.dart';
part 'ffi_backend/mount_guiding_operations.dart';
part 'ffi_backend/sequencer_recovery_operations.dart';
part 'ffi_backend/status_profile_operations.dart';
part 'ffi_backend/image_polar_operations.dart';
part 'ffi_backend/session_heartbeat_operations.dart';
part 'ffi_backend/bridge_model_mappers.dart';
part 'ffi_backend/depthlock_operations.dart';
part 'ffi_backend/mount_guard_operations.dart';

/// Map user-facing curve-fitting labels onto the native bridge's actual
/// autofocus method enum strings. "Trend Lines" is the V-curve/trend-line
/// implementation; "V-Curve" and "Quadratic" are labels earlier releases
/// stored. Any other label is passed as it is, and the bridge refuses it.
String autofocusCurveMethodForNativeBridge(String curveFitting) {
  return switch (curveFitting.trim().toLowerCase()) {
    'hyperbolic' => 'Hyperbolic',
    'parabolic' || 'quadratic' => 'Parabolic',
    'trend lines' || 'v-curve' || 'vcurve' || 'v_curve' || '' => 'VCurve',
    _ => curveFitting,
  };
}

/// The word a guider state has on the headless API and in [Phd2Status.state]
/// (`test_fixtures/guider_state/words.json`). An unknown state keeps PHD2's
/// own spelling.
String guiderActivityWord(bridge.GuiderActivity activity) => switch (activity) {
  bridge.GuiderActivity_Disconnected() => 'Disconnected',
  bridge.GuiderActivity_Connected() => 'Connected',
  bridge.GuiderActivity_Stopped() => 'Stopped',
  bridge.GuiderActivity_Calibrating() => 'Calibrating',
  bridge.GuiderActivity_Guiding() => 'Guiding',
  bridge.GuiderActivity_Looping() => 'Looping',
  bridge.GuiderActivity_Paused() => 'Paused',
  bridge.GuiderActivity_Settling() => 'Settling',
  bridge.GuiderActivity_LostLock() => 'LostLock',
  bridge.GuiderActivity_Unknown(:final field0) => field0,
};

/// The bridge's config for an operator-run autofocus.
bridge.AutofocusConfigApi autofocusConfigForBridge(AutofocusRequest request) =>
    bridge.AutofocusConfigApi(
      exposureTime: request.exposureTime,
      stepSize: request.stepSize,
      stepsOut: request.stepsOut,
      // `AutofocusConfigApi.method` selects the curve-fitting algorithm. The
      // request's `method` names the star metric and is not a native curve
      // enum.
      method: autofocusCurveMethodForNativeBridge(request.curveFitting),
      binning: request.binning,
      gain: request.gain,
      offset: request.offset,
      numberOfAttempts: request.numberOfAttempts,
      exposuresPerPoint: request.exposuresPerPoint,
      rSquaredThreshold: request.rSquaredThreshold,
      outerCropRatio: request.outerCropRatio,
      innerCropRatio: request.innerCropRatio,
      useBrightestNStars: request.useBrightestNStars,
      focuserSettleTimeMs: BigInt.from(request.focuserSettleTimeMs),
      backlashCompMethod: request.backlashCompMethod,
      backlashIn: request.backlashIn,
      backlashOut: request.backlashOut,
      measuredBacklashIn: request.measuredBacklashIn,
      failureHfrToleranceRatio: request.failureHfrToleranceRatio,
    );

const _logSource = 'FfiBackend';

abstract class _FfiBackendBase implements SkotiqBackend {
  final SkotiqDatabase? _database;

  /// Reads and writes the `.thumb.jpg` sidecars that keep `getImageThumbnail`
  /// off the full-frame decode path. One instance per backend so concurrent
  /// requests for the same frame share a single generation.
  final ThumbnailSidecarService _thumbnailSidecars;

  /// Cached broadcast stream for events - allows multiple subscribers
  Stream<SkotiqEvent>? _cachedEventStream;

  /// Subscription to polar alignment events - must be cancelled on dispose
  StreamSubscription<SkotiqEvent>? _polarAlignSubscription;

  @override
  bool get dispatchPluginNodesLocally => true;

  bool _disposed = false;

  final Stream<bridge.SkotiqEvent> Function() _openNativeEvents;

  /// Told once when the native event stream cannot be opened or ends while
  /// this backend is in use, with the reason.
  final void Function(String reason)? _onEventsLost;
  bool _eventsLostReported = false;

  _FfiBackendBase({
    SkotiqDatabase? database,
    ThumbnailSidecarService? thumbnailSidecars,
    Stream<bridge.SkotiqEvent> Function()? nativeEvents,
    void Function(String reason)? onEventsLost,
  }) : _database = database,
       _thumbnailSidecars = thumbnailSidecars ?? ThumbnailSidecarService(),
       _openNativeEvents = nativeEvents ?? _openBridgeEvents,
       _onEventsLost = onEventsLost;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _polarAlignSubscription?.cancel();
    _polarAlignSubscription = null;
    _polarAlignController.close();
    _cachedEventStream = null;

    Log.info('FfiBackend disposed', source: _logSource);
  }

  @override
  Stream<SkotiqEvent> get eventStream {
    if (_disposed) {
      throw StateError('Cannot access eventStream after dispose');
    }

    if (_cachedEventStream == null) {
      Log.info('Creating event stream from native bridge', source: _logSource);
      _cachedEventStream = _nativeEventStream()
          .map(wireEventFromTyped)
          .asBroadcastStream();

      Log.info('Event stream created as broadcast stream', source: _logSource);

      _polarAlignSubscription = _cachedEventStream!.listen(
        (event) {
          if (event.category == EventCategory.polarAlignment) {
            _polarAlignController.add(event.data);
          }
        },
        // [_nativeEventStream] has logged it; the app's own listeners get it.
        onError: (Object error) {},
      );
    }
    return _cachedEventStream!;
  }

  final _polarAlignController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// The native event stream, watched: an error is logged and passed on, and
  /// a stream that cannot be opened or ends before [dispose] is logged and
  /// reported to [_onEventsLost], since nothing reaches the app after that.
  Stream<bridge.SkotiqEvent> _nativeEventStream() {
    final Stream<bridge.SkotiqEvent> events;
    try {
      events = _openNativeEvents();
    } catch (e) {
      Log.error(
        'Failed to get the native event stream: $e',
        source: _logSource,
      );
      _reportEventsLost('the native event stream could not be opened: $e');
      return StreamController<bridge.SkotiqEvent>().stream;
    }
    return events.transform(
      StreamTransformer.fromHandlers(
        handleError: (error, stackTrace, sink) {
          Log.error(
            'The native event stream reported an error',
            source: _logSource,
            error: error,
            stackTrace: stackTrace,
          );
          sink.addError(error, stackTrace);
        },
        handleDone: (sink) {
          if (!_disposed) {
            Log.error('The native event stream ended', source: _logSource);
            _reportEventsLost('the native event stream ended');
          }
          sink.close();
        },
      ),
    );
  }

  /// Runs [_onEventsLost] in its own microtask: the loss can be found inside
  /// the [eventStream] getter while a provider builds, and a failing report
  /// must not break the stream it reports on.
  void _reportEventsLost(String reason) {
    if (_eventsLostReported) return;
    _eventsLostReported = true;
    final report = _onEventsLost;
    if (report == null) return;
    scheduleMicrotask(() {
      try {
        report(reason);
      } on Object catch (e, stackTrace) {
        Log.error(
          'The lost native event stream could not be reported',
          source: _logSource,
          error: e,
          stackTrace: stackTrace,
        );
      }
    });
  }
}

/// The Rust event stream, or a stream that never emits when the native
/// library is not loaded (nothing can produce an event then).
Stream<bridge.SkotiqEvent> _openBridgeEvents() =>
    bridge.NativeBridge.isNativeAvailable
    ? bridge.apiEventStream()
    : StreamController<bridge.SkotiqEvent>().stream;

/// FFI backend implementation that wraps the native Rust bridge
///
/// This backend uses direct FFI calls to the Rust native library
/// and is used by Desktop and Headless modes.
class FfiBackend extends _FfiBackendBase
    with
        _FfiDiscoveryCameraOperations,
        _FfiMountGuidingOperations,
        _FfiSequencerRecoveryOperations,
        _FfiStatusProfileOperations,
        _FfiImagePolarOperations,
        _FfiSessionHeartbeatOperations,
        _FfiDepthLockOperations,
        _FfiMountGuardOperations
    implements
        SkotiqBackend,
        EnvironmentalStatusBackend,
        DomeStatusBackend,
        DeviceQuirksBackend,
        VendorSdkBackend,
        MountGuardBackend {
  /// [thumbnailSidecars] is a seam for tests that need to observe or stub
  /// thumbnail generation without a live Rust bridge; production leaves it
  /// null and gets the default service. [nativeEvents] stands in for the Rust
  /// event stream the same way. [onEventsLost] is told once when the native
  /// event stream cannot be opened or ends while the backend is in use.
  FfiBackend({
    super.database,
    super.thumbnailSidecars,
    super.nativeEvents,
    super.onEventsLost,
  });

  /// Pure bridge conversion seams. They keep the native library out of mapper
  /// tests while production conversion stays centralized in
  /// [_FfiBackendBridgeModelMappers].
  @visibleForTesting
  EquipmentProfile profileFromBridgeForTesting(bridge.EquipmentProfile value) =>
      _fromBridgeProfile(value);

  @visibleForTesting
  bridge.EquipmentProfile profileToBridgeForTesting(EquipmentProfile value) =>
      _toBridgeProfile(value);
}
