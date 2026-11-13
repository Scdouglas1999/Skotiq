import '../models/imaging/frame_type_record.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import '../database/daos/images_dao.dart';
import '../database/database.dart';
import '../models/autofocus_progress.dart';
import '../models/depthlock/depthlock_models.dart';
import '../models/equipment_profile.dart';
import '../models/imaging/imaging_models.dart';
import '../models/mount_guard.dart';
import '../models/phd2_models.dart';
import '../models/plate_solver.dart';
import '../models/sequence/sequence_models.dart';
import '../models/site/location_settings.dart';
import '../services/adaptive_swap_service.dart';
import '../services/phd2_probe.dart';
import '../services/phd2_status_poll.dart';
import '../services/science/fits_header_writer.dart';
import '../services/stretch_pipeline_service.dart';
import '../services/thumbnail_sidecar_service.dart';
import '../utils/device_id.dart';
import 'bridge_error_message.dart';
import 'device_connect_exception.dart';
import 'skotiq_backend.dart';
import '../models/settings/app_settings.dart' as models;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../models/backend/device_capabilities.dart' as dart_caps;
import '../models/backend/device_status.dart' as dart_status;
import '../models/backend/device_types.dart' as dart_types;
import '../models/errors/skotiq_error.dart' as dart_error;
import 'bridge_event_codec.dart';
import '../services/ip_geolocation.dart';
import '../models/backend/backend_types.dart';
import '../services/logging_service.dart';

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
/// implementation; unknown legacy labels also fail safely to VCurve.
String autofocusCurveMethodForNativeBridge(String curveFitting) {
  return switch (curveFitting.trim().toLowerCase()) {
    'hyperbolic' => 'Hyperbolic',
    'parabolic' || 'quadratic' => 'Parabolic',
    _ => 'VCurve',
  };
}

abstract class _FfiBackendBase implements SkotiqBackend {
  final _logger = Logger('FfiBackend');
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

  _FfiBackendBase({
    SkotiqDatabase? database,
    ThumbnailSidecarService? thumbnailSidecars,
  }) : _database = database,
       _thumbnailSidecars = thumbnailSidecars ?? ThumbnailSidecarService();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _polarAlignSubscription?.cancel();
    _polarAlignSubscription = null;
    _polarAlignController.close();
    _cachedEventStream = null;

    _logger.info('FfiBackend disposed');
  }

  @override
  Stream<SkotiqEvent> get eventStream {
    if (_disposed) {
      throw StateError('Cannot access eventStream after dispose');
    }

    if (_cachedEventStream == null) {
      _logger.info('Creating event stream from native bridge');
      _cachedEventStream = _nativeEventStream().map((bridgeEvent) {
        final event = wireEventFromTyped(bridgeEvent);
        if (event.category == EventCategory.guiding) {
          _logger.info(
            'FfiBackend received guiding event: ${event.eventType} '
            'data=${event.data}',
          );
        }
        return event;
      }).asBroadcastStream();

      _logger.info('Event stream created as broadcast stream');

      _polarAlignSubscription = _cachedEventStream!.listen((event) {
        if (event.category == EventCategory.polarAlignment) {
          _polarAlignController.add(event.data);
        }
      });
    }
    return _cachedEventStream!;
  }

  final _polarAlignController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// The Rust event stream, or a stream that never emits when the native
  /// library is not loaded (nothing can produce an event then).
  Stream<bridge.SkotiqEvent> _nativeEventStream() {
    if (bridge.NativeBridge.isNativeAvailable) {
      try {
        return bridge.apiEventStream();
      } catch (e) {
        _logger.severe('Failed to get the native event stream: $e');
      }
    }
    return StreamController<bridge.SkotiqEvent>().stream;
  }
}

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
  /// null and gets the default service.
  FfiBackend({super.database, super.thumbnailSidecars});

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
