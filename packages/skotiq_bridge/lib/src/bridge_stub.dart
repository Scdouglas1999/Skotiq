// ignore_for_file: unused_field

/// Skotiq Bridge - Dart FFI bindings to Rust native code
///
/// This file provides the bridge to the Rust native library. The native
/// library is loaded dynamically and is the ONLY device path: every ASCOM,
/// Alpaca, INDI, native-vendor and PHD2 operation is executed in Rust.
///
/// When the native library is not available this bridge fails closed — it
/// returns empty device lists and throws from every hardware operation. There
/// is no Dart-side device implementation to fall back to and no built-in
/// simulator. Use INDI/ASCOM/Alpaca external simulators for testing instead.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'api_barrel.dart' as gen_api;
import 'device.dart' as gen_device;
import 'event.dart' as gen_event;
import 'state.dart' as gen_state;
import 'storage.dart' as gen_storage;
import 'frb_generated.dart' as frb;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

part 'bridge_stub/native_bridge_state.dart';
part 'bridge_stub/native_bridge_facade.dart';
part 'bridge_stub/runtime_operations.dart';
part 'bridge_stub/discovery_operations.dart';
part 'bridge_stub/connection_operations.dart';
part 'bridge_stub/equipment_operations.dart';
part 'bridge_stub/guiding_operations.dart';
part 'bridge_stub/sequencer_operations.dart';
part 'bridge_stub/storage_and_image_operations.dart';
part 'bridge_stub/depthlock_operations.dart';

// Error messages for the native-bridge-absent path

/// Error message thrown when a device operation is called without the native
/// bridge. Rust is the only device path, so there is nothing to fall back to.
const _nativeMissingErrorMessage = '''
Native bridge not available.

Possible causes:
1. Native library failed to load - check build output
2. Running on unsupported platform (web)
3. DLL/dylib not found in expected location

For development: Use INDI/ASCOM/Alpaca simulators. There is no Dart-side device
implementation and no built-in simulator, so this operation fails closed rather
than reporting fake data.
''';

Never _nativeBridgeRequired(String operation) {
  throw UnsupportedError(
    'Operation "$operation" requires the native bridge.\n$_nativeMissingErrorMessage',
  );
}

bool _isPhd2DeviceId(String deviceId) =>
    deviceId == 'phd2' ||
    deviceId == 'phd2_guider' ||
    deviceId.startsWith('phd2:') ||
    deviceId.startsWith('phd2://');

String _canonicalGuiderDeviceId(String deviceId) {
  if (_isPhd2DeviceId(deviceId)) {
    return 'phd2_guider';
  }
  return deviceId;
}

// Type aliases over the FRB-generated types

// From device.dart
typedef DeviceType = gen_device.DeviceType;
typedef DriverType = gen_device.DriverType;
typedef CameraStatus = gen_device.CameraStatus;
typedef DeviceInfo = gen_device.DeviceInfo;
typedef FilterWheelStatus = gen_device.FilterWheelStatus;
typedef FocuserStatus = gen_device.FocuserStatus;
typedef MountStatus = gen_device.MountStatus;
typedef PierSide = gen_device.PierSide;
typedef RotatorStatus = gen_device.RotatorStatus;
typedef TrackingRate = gen_device.TrackingRate;

// From state.dart
typedef EquipmentProfile = gen_state.EquipmentProfile;

// From storage.dart
typedef AppSettings = gen_storage.AppSettings;
typedef ObserverLocation = gen_storage.ObserverLocation;

// From api.dart
typedef AutofocusConfigApi = gen_api.AutofocusConfigApi;
typedef AutofocusResultApi = gen_api.AutofocusResultApi;
typedef CapturedImageResult = gen_api.CapturedImageResult;
typedef ImageStatsResult = gen_api.ImageStatsResult;
typedef Phd2Status = gen_api.Phd2Status;
typedef Phd2StarImage = gen_api.Phd2StarImage;
typedef PlateSolveResult = gen_api.PlateSolveResult;
// Note: SequencerState is NOT typedefed because FRB's SequencerState is a class,
// but we use a local enum for internal state management (see _InternalSequencerState below)

// From event.dart
typedef SkotiqEvent = gen_event.SkotiqEvent;
typedef EventSeverity = gen_event.EventSeverity;
typedef EventCategory = gen_event.EventCategory;
typedef PolarAlignmentEvent = gen_event.PolarAlignmentEvent;

// Extension on FRB-generated DeviceType

extension DeviceTypeExtension on DeviceType {
  String get displayName {
    switch (this) {
      case DeviceType.camera:
        return 'Camera';
      case DeviceType.mount:
        return 'Mount';
      case DeviceType.focuser:
        return 'Focuser';
      case DeviceType.filterWheel:
        return 'Filter Wheel';
      case DeviceType.guider:
        return 'Guider';
      case DeviceType.dome:
        return 'Dome';
      case DeviceType.rotator:
        return 'Rotator';
      case DeviceType.weather:
        return 'Weather';
      case DeviceType.safetyMonitor:
        return 'Safety Monitor';
      case DeviceType.switch_:
        return 'Switch';
      case DeviceType.coverCalibrator:
        return 'Cover Calibrator';
    }
  }
}

// Enums unique to bridge fallback layer (not in FRB-generated code)

/// Device connection state
enum ConnectionState { disconnected, connecting, connected, error }

/// Frame type for camera exposures
enum FrameType { light, dark, flat, bias, darkFlat }

/// Dome shutter state
enum ShutterState { open, closed, opening, closing, error, unknown }

// EventSeverity, EventCategory, PolarAlignmentEvent, and SkotiqEvent are now typedefed from event.dart

// Data classes unique to bridge fallback layer (not in FRB-generated code)

/// Session state from native
class NativeSessionState {
  final bool isActive;
  final int? startTime;
  final String? targetName;
  final double? targetRa;
  final double? targetDec;
  final int totalExposures;
  final int completedExposures;
  final double totalIntegrationSecs;
  final String? currentFilter;
  final bool isGuiding;
  final bool isCapturing;
  final bool isDithering;

  NativeSessionState({
    required this.isActive,
    this.startTime,
    this.targetName,
    this.targetRa,
    this.targetDec,
    required this.totalExposures,
    required this.completedExposures,
    required this.totalIntegrationSecs,
    this.currentFilter,
    required this.isGuiding,
    required this.isCapturing,
    required this.isDithering,
  });
}

/// Internal fallback event - used for simulator mode
/// This is different from gen_event.SkotiqEvent which uses EventPayload
class _FallbackSkotiqEvent {
  final int timestamp;
  final gen_event.EventSeverity severity;
  final gen_event.EventCategory category;
  final String eventType;
  final Map<String, dynamic> data;

  _FallbackSkotiqEvent({
    required this.timestamp,
    required this.severity,
    required this.category,
    required this.eventType,
    required this.data,
  });
}

/// Image statistics (unique to bridge fallback layer - different from ImageStatsResult)
class ImageStats {
  final double min;
  final double max;
  final double mean;
  final double median;
  final double stdDev;
  final double mad;

  ImageStats({
    required this.min,
    required this.max,
    required this.mean,
    required this.median,
    required this.stdDev,
    required this.mad,
  });
}

/// Sequencer status (unique to bridge fallback layer - different from SequencerState)
class SequencerStatus {
  final String state;
  final String? currentNodeId;
  final String? currentNodeName;
  final double progress;
  final String? message;

  SequencerStatus({
    required this.state,
    this.currentNodeId,
    this.currentNodeName,
    required this.progress,
    this.message,
  });
}

/// Checkpoint information for crash recovery
class CheckpointInfoApi {
  final String sequenceName;
  final String timestamp; // ISO-8601 format
  final int completedExposures;
  final double completedIntegrationSecs;
  final bool canResume;
  final int ageSeconds;

  CheckpointInfoApi({
    required this.sequenceName,
    required this.timestamp,
    required this.completedExposures,
    required this.completedIntegrationSecs,
    required this.canResume,
    required this.ageSeconds,
  });
}

/// Sequencer state enum for local state management
/// Note: This is hidden from library exports and FRB's SequencerState (a class) is exported instead
enum SequencerState { idle, running, paused, stopping, completed, failed }
