/// Skotiq OTA Update System
///
/// Provides self-hosted OTA updates with two mechanisms:
/// - LAN Push: Dev machine pushes updates directly to targets on local network
/// - Pull-Based: App checks update server on startup, prompts user to download
library;

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
// The update state machine, and the view of it the windows show.
export 'src/services/update_controller.dart';
export 'src/services/update_notifier.dart';
