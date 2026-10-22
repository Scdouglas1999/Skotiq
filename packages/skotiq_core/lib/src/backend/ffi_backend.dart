import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../models/settings/app_settings.dart' as models;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_api;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_caps;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_device;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;

// Import pure Dart types from backend_types for return types
import '../models/backend/device_capabilities.dart' as dart_caps;
import '../models/backend/device_status.dart' as dart_status;
import '../models/backend/device_types.dart' as dart_types;
import '../models/errors/skotiq_error.dart' as dart_error;
import 'bridge_event_mapper.dart' show recoveryFieldsFromTyped;
import '../services/ip_geolocation.dart';

part 'ffi_backend/event_mapping.dart';
part 'ffi_backend/type_mappers.dart';
part 'ffi_backend/discovery_camera_operations.dart';
part 'ffi_backend/mount_guiding_operations.dart';
part 'ffi_backend/sequencer_recovery_operations.dart';
part 'ffi_backend/status_profile_operations.dart';
part 'ffi_backend/image_polar_operations.dart';
part 'ffi_backend/session_heartbeat_operations.dart';
part 'ffi_backend/bridge_model_mappers.dart';
part 'ffi_backend/depthlock_operations.dart';

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

  /// Whether this backend has been disposed
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

    // Return cached broadcast stream to allow multiple subscribers
    if (_cachedEventStream == null) {
      _logger.info('Creating event stream from native bridge');
      _cachedEventStream = bridge.NativeBridge.eventStream().map((bridgeEvent) {
        // Extract eventType and data from the EventPayload
        final payloadInfo = _extractPayloadInfo(bridgeEvent.payload);
        final category = _fromBridgeCategory(bridgeEvent.category);

        // Log guiding events at info level for diagnostics
        if (category == EventCategory.guiding) {
          _logger.info(
            'FfiBackend received guiding event: ${payloadInfo.$1} data=${payloadInfo.$2}',
          );
        }

        return SkotiqEvent(
          timestamp: bridgeEvent.timestamp,
          severity: _fromBridgeSeverity(bridgeEvent.severity),
          category: category,
          eventType: payloadInfo.$1,
          data: payloadInfo.$2,
        );
      }).asBroadcastStream();

      _logger.info('Event stream created as broadcast stream');

      // Wire up polar alignment events to the dedicated stream
      // Store subscription for proper cleanup on dispose
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
        _FfiDepthLockOperations
    implements SkotiqBackend, EnvironmentalStatusBackend, DomeStatusBackend {
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

  /// The `(eventType, data)` pair a typed sequencer payload becomes on its way
  /// into [SkotiqEvent.data].
  ///
  /// A seam, not a reimplementation: it calls the same private mapper the event
  /// stream uses, so a test can assert what actually reaches the map without
  /// standing up the native bridge. Worth the seam because this is the only
  /// hop between the typed FRB payload and the untyped map every listener
  /// reads — dropping a field here puts NULLs back in `captured_images` with
  /// nothing on either side of it noticing.
  @visibleForTesting
  (String, Map<String, dynamic>) sequencerEventInfoForTesting(dynamic event) =>
      _extractSequencerEventInfo(event);

  /// Family seams matching [sequencerEventInfoForTesting], one per union the
  /// event stream dispatches. The mappers take `dynamic`, so a test can hand
  /// a stand-in whose runtime type name mimics a generated variant this build
  /// has no arm for — the only way to reach the unread fallback while every
  /// real variant is mapped.
  @visibleForTesting
  (String, Map<String, dynamic>) safetyEventInfoForTesting(dynamic event) =>
      _extractSafetyEventInfo(event);
  @visibleForTesting
  (String, Map<String, dynamic>) systemEventInfoForTesting(dynamic event) =>
      _extractSystemEventInfo(event);
  @visibleForTesting
  (String, Map<String, dynamic>) equipmentEventInfoForTesting(dynamic event) =>
      _extractEquipmentEventInfo(event);
  @visibleForTesting
  (String, Map<String, dynamic>) guidingEventInfoForTesting(dynamic event) =>
      _extractGuidingEventInfo(event);
  @visibleForTesting
  (String, Map<String, dynamic>) imagingEventInfoForTesting(dynamic event) =>
      _extractImagingEventInfo(event);
  @visibleForTesting
  (String, Map<String, dynamic>) depthLockEventInfoForTesting(dynamic event) =>
      _extractDepthLockEventInfo(event);
}
