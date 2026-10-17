import 'dart:async';

import '../../models/backend/backend_types.dart';
import '../../providers/settings_provider.dart' show LocationSettings;

/// Cross-cutting backend concerns that every implementation must answer.
///
/// What this role owns:
///   * The asynchronous event stream of backend-side events (device, sequence,
///     guiding, recovery, etc.) — every `skotiq_core` consumer that wants
///     to observe state changes subscribes here.
///   * The polar-alignment progress stream (separate from the main bus because
///     of its higher-frequency, UI-only nature; kept here so disconnected
///     backends can still return an empty stream rather than crashing).
///   * Lifecycle (`dispose`) and the "should this process execute plugin
///     nodes locally" flag.
///   * Internet-based geolocation fallback (no device required).
///
/// What this role deliberately does NOT own:
///   * Any device-bound operation — see [DeviceBackend].
///   * Any imaging / plate-solving operation — see [ImagingBackend].
///   * Any sequence / recovery / checkpoint operation — see [SequencerBackend].
///   * Profile / settings persistence — see [ProfileSettingsBackend].
///   * Guiding — see [GuidingBackend].
///
/// Every concrete backend implements [DiagnosticsBackend] because the marker
/// [SkotiqBackend] composes it; future role-only consumers that just need
/// the event stream (e.g., log viewer, status banner) can depend on
/// [DiagnosticsBackend] directly.
abstract class DiagnosticsBackend {
  /// Event stream for backend events
  Stream<SkotiqEvent> get eventStream;

  /// Whether this process should execute PluginNode requests from the event
  /// stream and post the verdict back to the sequencer.
  ///
  /// Local FFI/headless backends own the native executor and return true.
  /// Network clients return false because the remote host is responsible for
  /// dispatching plugin nodes from its own installed plugin host.
  bool get dispatchPluginNodesLocally;

  /// Event stream for polar alignment updates
  Stream<Map<String, dynamic>> get polarAlignmentEvents;

  /// Dispose of backend resources.
  ///
  /// Must be called when the backend is no longer needed to prevent
  /// memory leaks and ensure proper cleanup of streams, subscriptions,
  /// and network connections.
  void dispose();

  /// Get current location from internet (IP-based)
  Future<LocationSettings> getLocationFromInternet();
}
