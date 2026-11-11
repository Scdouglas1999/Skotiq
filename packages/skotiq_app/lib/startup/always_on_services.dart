import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../screens/imaging/widgets/depthlock/depthlock_hint.dart';
import '../screens/session_review/auto_integration_service.dart';
import '../services/location_sync_service.dart';

/// What this process is, decided once at launch.
enum AppRole {
  /// A desktop window that owns the hardware.
  hostGui,

  /// The windowless daemon (`--headless`) that owns the hardware.
  hostDaemon,

  /// A desktop window driving another computer's rig.
  linkedClient,

  /// The phone or tablet app.
  mobile,
}

const _everyRole = {
  AppRole.hostGui,
  AppRole.hostDaemon,
  AppRole.linkedClient,
  AppRole.mobile,
};

/// Roles with a screen and a person in front of it.
const _windows = {AppRole.hostGui, AppRole.linkedClient, AppRole.mobile};

/// Roles that own the hardware and the database.
const _hosts = {AppRole.hostGui, AppRole.hostDaemon};

/// A provider that does its work only while something listens to it, and
/// which must therefore be listened to for the life of the app.
class AlwaysOnService {
  const AlwaysOnService(this.name, this.provider, this.roles, this.does);

  final String name;
  final ProviderListenable<Object?> provider;
  final Set<AppRole> roles;

  /// What stops happening when this is not running.
  final String does;
}

/// Every always-on service and the roles that run it.
///
/// This table is the only place a side-effect provider is switched on for the
/// life of the app. A provider that is merely defined, or watched by one
/// screen, runs only while that screen is open: that is how the USB
/// disconnect log, hotplug refresh and the recovery alerts came to exist
/// without ever running.
///
/// Stopping: each entry is held by a container subscription, closed by
/// [AlwaysOnServices.stop]; the provider's own `onDispose` releases what it
/// holds when the container is disposed.
final List<AlwaysOnService> alwaysOnServices = [
  // Notifications and alerts.
  AlwaysOnService(
    'notification router',
    notificationRouterProvider,
    _everyRole,
    'in-app banners everywhere; Discord, email, Telegram, Pushover, MQTT and '
        'webhook delivery on a host',
  ),
  AlwaysOnService(
    'push notification queue',
    pushNotificationServiceProvider,
    _everyRole,
    'the queue the remote access server delivers to paired phones',
  ),
  AlwaysOnService(
    'error toasts',
    errorNotificationBridgeProvider,
    _windows,
    'backend errors and warnings shown as toasts on every screen',
  ),
  AlwaysOnService(
    'mount guard alarm',
    mountGuardAlarmProvider,
    _windows,
    'the alarm when the mount moves on its own or loses its position',
  ),
  AlwaysOnService(
    'mount guard settings',
    mountGuardSettingsSyncProvider,
    _hosts,
    "the native guard following the operator's solve-sync-resume choice",
  ),

  // Recovery.
  AlwaysOnService(
    'recovery events',
    recoveryEventBridgeProvider,
    _everyRole,
    'the recovery banner, the recovering run state and the recovery history '
        'the session record keeps',
  ),
  AlwaysOnService(
    'recovery sound',
    recoveryAudibleBridgeProvider,
    // A daemon has nobody in front of it to hear a sound.
    _windows,
    'the alert sound when a run enters recovery (Settings: audible alerts)',
  ),
  AlwaysOnService(
    'recovery push',
    recoveryPushBridgeProvider,
    // Phones are paired with the host; a client has no queue to deliver from.
    _hosts,
    'the phone alert when a run enters and leaves recovery '
        '(Settings: push critical alerts)',
  ),

  // Equipment.
  AlwaysOnService(
    'USB disconnect log',
    usbDisconnectEventBridgeProvider,
    _everyRole,
    'the disconnect count in session diagnostics, equipment health and '
        "Tonight's session numbers",
  ),
  AlwaysOnService(
    'hotplug discovery refresh',
    hotplugEventBridgeProvider,
    _everyRole,
    'device lists refreshing when a device is plugged in or removed',
  ),
  AlwaysOnService(
    'capability refresh on connect',
    capabilityRefreshOnConnectProvider,
    _hosts,
    'fresh device capabilities after a reconnect',
  ),
  AlwaysOnService(
    'camera preset seed',
    cameraPresetsSeedOnConnectProvider,
    _hosts,
    'the unity gain preset seeded the first time a camera connects',
  ),
  AlwaysOnService(
    'science camera values',
    scienceCameraAutoConfigProvider,
    _everyRole,
    'read noise, gain and saturation kept in step with the connected camera',
  ),
  AlwaysOnService(
    'focuser temperature compensation',
    focuserTempCompensationProvider,
    _hosts,
    'focus following temperature outside a sequence (off until enabled)',
  ),
  AlwaysOnService(
    'cover and panel status',
    coverCalibratorStatusPollerProvider,
    _everyRole,
    'cover and flat panel state, which no driver reports on its own',
  ),
  AlwaysOnService(
    'switch channels',
    switchChannelPollerProvider,
    _everyRole,
    'switch channel state, which no driver reports on its own',
  ),

  // Meridian flip.
  AlwaysOnService(
    'meridian flip disconnect guard',
    meridianFlipDisconnectGuardProvider,
    _everyRole,
    'an in-flight flip ending when the mount drops offline',
  ),
  AlwaysOnService(
    'standalone meridian monitor',
    meridianFlipStandaloneMonitorProvider,
    _everyRole,
    'the meridian alert outside a sequence (off until enabled)',
  ),

  // Run and session.
  AlwaysOnService(
    'last ended run',
    lastEndedRunProvider,
    _windows,
    'Tonight showing the finished night whichever screen was open at its end',
  ),
  AlwaysOnService(
    'session frames seed',
    sessionNightSeedProvider,
    _everyRole,
    "the night's frames list rebuilt from the database after a restart",
  ),
  AlwaysOnService(
    'autofocus and centering frames',
    autofocusPreviewFeederProvider,
    _everyRole,
    'autofocus, centering and polar alignment frames reaching the main image',
  ),
  AlwaysOnService(
    'night narrator',
    narratorServiceProvider,
    // Narration is written for a screen; a daemon's clients run their own.
    _windows,
    'the Night Narrator detectors for the active session',
  ),
  AlwaysOnService(
    'post-session integration',
    autoIntegrationCoordinatorProvider,
    _everyRole,
    'integration starting by itself when a run completes',
  ),
  AlwaysOnService(
    'end-of-night calibration',
    endOfNightCalibrationCoordinatorProvider,
    _everyRole,
    "calibration frames starting when the night's imaging ends",
  ),
  AlwaysOnService(
    'scheduler re-evaluation',
    schedulerAutoReevalProvider,
    _windows,
    'the target queue re-scoring when targets, goals or constraints change',
  ),
  AlwaysOnService(
    'co-imaging baton',
    coImagingBatonSchedulerProvider,
    _everyRole,
    'a shared session handing the night east as the target sets',
  ),
  AlwaysOnService(
    'live stacking kill switch',
    liveStackingKillSwitchBridgeProvider,
    _hosts,
    '"Disable broadcast everywhere" applying from the first moment',
  ),
  AlwaysOnService(
    'Home Assistant discovery',
    homeAssistantDiscoveryProvider,
    _hosts,
    'the observatory published as Home Assistant entities (off until enabled)',
  ),
  AlwaysOnService(
    'open plan kept',
    openPlanLifecycleProvider,
    // A daemon's plan is the one its clients opened on it.
    _hosts,
    'the plan open in the editor coming back after a restart',
  ),

  // Host and client kept in step.
  AlwaysOnService(
    'runtime mirror (host)',
    hostRuntimeMirrorProvider,
    _everyRole,
    'solves, centering, autofocus and the frame on screen published to '
        'linked clients',
  ),
  AlwaysOnService(
    'runtime reports (client)',
    clientRuntimeReporterProvider,
    _windows,
    'results a client computes reaching the host and the other clients',
  ),
  AlwaysOnService(
    'host state announcer',
    hostStateAnnouncerProvider,
    _windows,
    "a framing target set on the host's screen reaching linked clients",
  ),
  AlwaysOnService(
    'host local sync',
    hostLocalSyncProvider,
    // It refreshes what a host window shows after a client changed it.
    _windows,
    "a host window following changes a client made through the server",
  ),
  AlwaysOnService(
    'remote session sync',
    remoteSessionSyncProvider,
    _windows,
    "a client mirroring the host's profiles, devices and run",
  ),
  AlwaysOnService(
    'sequence library sync',
    sequenceLibrarySyncProvider,
    _windows,
    "a client's saved plans list following the host's",
  ),
  AlwaysOnService(
    'sequence editor sync (client)',
    remoteSequenceEditorSyncProvider,
    _windows,
    "a client's Builder following the host's open plan",
  ),
  AlwaysOnService(
    'sequence editor mirror (host)',
    masterSequenceEditorMirrorProvider,
    _windows,
    "the host's open plan pushed to linked clients as it is edited",
  ),
  AlwaysOnService(
    'DepthLock tip dismissal',
    depthLockHintDismissalSyncProvider,
    _windows,
    'a dismissed DepthLock tip staying dismissed on both ends of a link',
  ),

  AlwaysOnService(
    'location sync',
    locationSyncProvider,
    // A daemon's linked clients read the site from the native store, so it
    // must follow the stored settings there too.
    _everyRole,
    "the planetarium and the host's native site following the site in "
        'Settings',
  ),
];

/// The always-on services running in one container.
class AlwaysOnServices {
  AlwaysOnServices._(this.role, this._subscriptions, this.running);

  final AppRole role;
  final List<ProviderSubscription<Object?>> _subscriptions;

  /// Names of the services that started, in table order.
  final List<String> running;

  /// Stops keeping the services alive. Safe to call more than once.
  void stop() {
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    _subscriptions.clear();
  }
}

/// Starts every service [role] runs, plus [platformServices] (for services
/// that live in an app and cannot be named from this package).
///
/// Each is listened to, not read: a provider that was only read is not rebuilt
/// when what it watches changes (a backend swap), and would quietly stop.
/// One service failing to start is logged and does not stop the others.
AlwaysOnServices startAlwaysOnServices(
  ProviderContainer container,
  AppRole role, {
  List<AlwaysOnService>? services,
  List<AlwaysOnService> platformServices = const [],
}) {
  final logger = container.read(loggingServiceProvider);
  final subscriptions = <ProviderSubscription<Object?>>[];
  final running = <String>[];

  for (final service in [
    ...services ?? alwaysOnServices,
    ...platformServices
  ]) {
    if (!service.roles.contains(role)) continue;
    void failed(Object error, StackTrace stack) {
      logger.error(
        'Always-on service "${service.name}" failed: $error. Not running: '
        '${service.does}.',
        source: 'AlwaysOnServices',
        fields: {'stack': '$stack'},
      );
    }

    try {
      subscriptions.add(
        container.listen<Object?>(
          service.provider,
          (_, __) {},
          onError: failed,
        ),
      );
      running.add(service.name);
    } catch (error, stack) {
      failed(error, stack);
    }
  }

  logger.info(
    'Always-on services started',
    source: 'AlwaysOnServices',
    fields: {'role': role.name, 'count': running.length},
  );
  return AlwaysOnServices._(role, subscriptions, running);
}
