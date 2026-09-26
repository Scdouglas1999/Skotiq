/// Nightshade OTA Update System
///
/// Provides self-hosted OTA updates with two mechanisms:
/// - LAN Push: Dev machine pushes updates directly to targets on local network
/// - Pull-Based: App checks update server on startup, prompts user to download
library;

import 'dart:async';
import 'src/models/update_manifest.dart';

// Models
export 'src/models/update_manifest.dart';
export 'src/models/update_state.dart';

// Services
export 'src/services/update_service.dart';
export 'src/services/update_downloader.dart';
export 'src/services/android_installer.dart';
export 'src/services/github_release_source.dart';
export 'src/services/update_prompt_store.dart';
export 'src/services/update_verifier.dart';
export 'src/services/lan_push_receiver.dart';
// Adapter interface that the headless API depends on. Wraps
// UpdateService for the production wiring and lets the test suite
// substitute a fake without touching disk / Process.start.
export 'src/services/update_controller.dart';

// Providers
export 'src/providers/update_provider.dart';

// Widgets
export 'src/widgets/update_manager_widget.dart';

/// Global stream for LAN push update notifications
/// Used to bridge main.dart's LanPushReceiver with the UI
class LanPushNotifier {
  static final _controller = StreamController<LanPushEvent>.broadcast();

  /// Stream of LAN push events
  static Stream<LanPushEvent> get stream => _controller.stream;

  /// Notify that an update was received
  static void notifyUpdateReceived(
    UpdateManifest manifest,
    String stagingPath,
  ) {
    _controller.add(LanPushEvent.received(manifest, stagingPath));
  }

  /// Notify progress
  static void notifyProgress(
    int received,
    int total,
    double progress,
    String message,
  ) {
    _controller.add(LanPushEvent.progress(received, total, progress, message));
  }

  /// Notify error
  static void notifyError(String error) {
    _controller.add(LanPushEvent.error(error));
  }
}

/// Event types for LAN push notifications
sealed class LanPushEvent {
  const LanPushEvent();

  factory LanPushEvent.received(UpdateManifest manifest, String stagingPath) =
      LanPushReceivedEvent;
  factory LanPushEvent.progress(
    int received,
    int total,
    double progress,
    String message,
  ) = LanPushProgressEvent;
  factory LanPushEvent.error(String error) = LanPushErrorEvent;
}

class LanPushReceivedEvent extends LanPushEvent {
  final UpdateManifest manifest;
  final String stagingPath;
  const LanPushReceivedEvent(this.manifest, this.stagingPath);
}

class LanPushProgressEvent extends LanPushEvent {
  final int received;
  final int total;
  final double progress;
  final String message;
  const LanPushProgressEvent(
    this.received,
    this.total,
    this.progress,
    this.message,
  );
}

class LanPushErrorEvent extends LanPushEvent {
  final String error;
  const LanPushErrorEvent(this.error);
}
