// Shared helpers for wiring the OTA update stack into both the
// GUI (`desktop_app_bootstrap.dart`) and the headless
// (`main_headless.dart`) entry points.
//
// Pre-only the GUI bootstrap constructed `UpdateService` +
// `LanPushReceiver`. The headless daemon had no equivalent, so a phone
// operator connected to a Pi-hosted server could not check or apply
// updates without physical access to the box. This module centralises
// the construction logic so both entry points behave identically.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_updater/skotiq_updater.dart';
import 'package:path/path.dart' as p;

import '../secret_file.dart';

/// Bundle returned by [provisionUpdateStack]. Carries the
/// [UpdateController] (which owns the underlying [UpdateService] and is
/// the API surface the headless server consumes) plus the LAN-push
/// receiver so the bootstrap can stop it on shutdown.
class UpdateStack {
  final UpdateController controller;
  final LanPushReceiver lanPushReceiver;
  final String pushSecret;

  UpdateStack({
    required this.controller,
    required this.lanPushReceiver,
    required this.pushSecret,
  });

  /// Tear down the full stack. Idempotent; both sub-components handle
  /// double-close gracefully.
  Future<void> dispose() async {
    await lanPushReceiver.stopServer();
    await controller.dispose();
  }
}

/// Construct + bootstrap the production update stack.
///
/// Always returns a stack: with no [serverUrl] and no
/// `SKOTIQ_UPDATE_SERVER`, the source is the project's GitHub releases.
/// (The nullable return is kept because callers already handle it, and
/// because the construction below can still fail.)
///
/// Errors during construction are surfaced via [logger] and re-thrown so
/// the caller can decide whether to fall back to a no-OTA configuration
/// (the headless daemon currently does — OTA is non-essential to
/// imaging).
Future<UpdateStack?> provisionUpdateStack({
  required String currentVersion,
  required int currentBuildNumber,
  required LoggingService logger,
  required String logSource,
  String? serverUrl,
  String channel = 'stable',
  Future<void> Function()? applySafetyCheck,
}) async {
  final resolvedUrl = (serverUrl?.trim().isNotEmpty ?? false)
      ? serverUrl!.trim()
      : (Platform.environment['SKOTIQ_UPDATE_SERVER']?.trim() ?? '');
  final resolvedChannel =
      (Platform.environment['SKOTIQ_UPDATE_CHANNEL']?.trim().isNotEmpty ??
          false)
      ? Platform.environment['SKOTIQ_UPDATE_CHANNEL']!.trim()
      : channel;

  final appData = await resolveSkotiqDataDirectory();
  final pushSecret = await getOrCreatePushSecret(logger, logSource: logSource);

  final service = UpdateService(
    currentVersion: currentVersion,
    currentBuildNumber: currentBuildNumber,
  );
  // An explicit update server wins — that is how an appliance is pointed at a
  // private build host. With none set, read the project's GitHub releases,
  // the same source the GUI uses, so a headless rig is not left as the one
  // install that can never see an update.
  if (resolvedUrl.isNotEmpty) {
    service.configure(serverUrl: resolvedUrl, channel: resolvedChannel);
  } else {
    service.configureGithubSource(
      owner: kSkotiqReleaseOwner,
      repo: kSkotiqReleaseRepo,
      channel: resolvedChannel,
    );
  }

  // Observability gap: a build with an update source but no compiled-in
  // SKOTIQ_UPDATE_PUBLIC_KEY looks live (checks succeed) until a
  // download is attempted, where it fails closed. Warn loudly so this is
  // not mistaken for working OTA. The stack is still returned — fail-closed
  // is preserved downstream in downloadAndStage / applyUpdate.
  if (!service.canAuthenticateUpdates) {
    logger.warning(
      'An OTA update source is configured but this build has no trusted '
      'update public key (SKOTIQ_UPDATE_PUBLIC_KEY) compiled in. Update '
      'checks will run, but downloads will be refused (fail-closed). Provision '
      'the vendor public key at build time to enable signed OTA updates.',
      source: logSource,
      fields: {
        'update_source': resolvedUrl.isNotEmpty ? resolvedUrl : 'github',
        'channel': resolvedChannel,
      },
    );
  }

  final controller = UpdateController(
    service: service,
    currentVersion: currentVersion,
    currentBuildNumber: currentBuildNumber,
    stateDirectory: appData,
    channel: resolvedChannel,
    serverUrl: resolvedUrl.isEmpty ? null : resolvedUrl,
    applySafetyCheck: applySafetyCheck,
  );
  await controller.bootstrap();

  final receiver = LanPushReceiver(
    currentVersion: currentVersion,
    currentBuildNumber: currentBuildNumber,
    pushSecret: pushSecret,
  );

  return UpdateStack(
    controller: controller,
    lanPushReceiver: receiver,
    pushSecret: pushSecret,
  );
}

/// Load or generate the LAN-push authentication secret. Persisted under
/// the application-support directory so it survives restarts. Used by
/// both GUI and headless bootstraps.
///
/// Exposed at library level so unit tests can pre-seed a fixed secret in
/// the AppData root. [appDataDir] overrides where that root is, which is what
/// lets a test assert the file mode without a platform-channel mock; production
/// callers leave it null and get the real application-support directory.
Future<String> getOrCreatePushSecret(
  LoggingService logger, {
  required String logSource,
  Directory? appDataDir,
}) async {
  final appData = appDataDir ?? await resolveSkotiqDataDirectory();
  final secretFile = File(p.join(appData.path, 'push_secret.txt'));

  if (await secretFile.exists()) {
    final secret = (await secretFile.readAsString()).trim();
    if (secret.isNotEmpty) {
      // Repair a file an older build created world-readable.
      await restrictSecretFile(secretFile);
      return secret;
    }
  }

  final secret = LanPushReceiver.generatePushSecret();
  await writeSecretFile(secretFile, secret);
  logger.info(
    'Generated new LAN push secret. Configure this on the push tool.',
    source: logSource,
    fields: {'secret_path': secretFile.path},
  );
  return secret;
}

/// Random 32-byte hex string. Used by the GUI bootstrap for the
/// persistent bearer token (kept here so future refactors that need a
/// matching helper for, say, an update-side signing key have one place
/// to add it).
String generateRandomHex(int byteCount) {
  final rng = Random.secure();
  final bytes = List<int>.generate(byteCount, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
