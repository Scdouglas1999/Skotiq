// ignore_for_file: unused_field

part of '../bridge_stub.dart';

final _nativeBridge = _NativeBridgeImplementation();

/// Process-wide mutable state shared by the domain-specific bridge operations.
final class _NativeBridgeImplementation {
  bool _initialized = false;
  bool _nativeAvailable = false;
  DynamicLibrary? _nativeLib;
  String? _loadedNativeLibraryPath;
  final _eventController =
      StreamController<_FallbackSkotiqEvent>.broadcast();

  final Map<String, bool> _connectedDevices = {};
  final Map<String, DeviceInfo> _connectedDeviceInfo = {};

  final Map<DeviceType, List<DeviceInfo>> _discoveryCache = {};
  DateTime? _discoveryCacheTime;
  final _discoveryCacheTtl = const Duration(seconds: 60);
  Completer<void>? _discoverySweepInProgress;

  SequencerState _sequencerState = SequencerState.idle;
  String? _loadedSequenceJson;
  bool _sequencerEventsSubscribed = false;
  bool _simulationMode = false;
}
