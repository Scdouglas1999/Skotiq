import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

const _headlessLogSource = 'HeadlessMain';

/// subscribe to [DiskSpaceGuardService.events] and translate the
/// stream into structured log entries plus a hard sequencer-stop on the
/// blocking severity. The watchdog itself is started here against the
/// configured capture path so the headless run does not need an interactive
/// "Start watchdog" button.
///
/// The watchdog runs even when no sequence is active so the operator's logs
/// always show why a sequence aborts later if the disk fills overnight.
Future<StreamSubscription<DiskSpaceWatchdogEvent>?> startDiskSpaceWatchdog({
  required ProviderContainer container,
  required DiskSpaceGuardService guard,
  required LoggingService logger,
}) async {
  // The capture path lives in the settings store. We listen to changes so a
  // mid-run setting change (the operator pointing at a different drive)
  // does not leave the watchdog polling a stale path.
  final settings = await container.read(appSettingsProvider.future);
  final initialPath = settings.imageOutputPath;
  if (initialPath.isEmpty) {
    logger.warning(
      'Disk-space watchdog disabled: no capture directory configured. '
      'Set the capture path in App Settings to enable overnight disk-fill '
      'protection.',
      source: _headlessLogSource,
    );
    return null;
  }

  guard.start(capturePath: initialPath);
  logger.info(
    'Disk-space watchdog started for capturePath=$initialPath',
    source: _headlessLogSource,
  );

  var currentPath = initialPath;
  container.listen(appSettingsProvider, (previous, next) {
    final path = next.valueOrNull?.imageOutputPath;
    if (path == null || path.isEmpty || path == currentPath) return;
    currentPath = path;
    guard.start(capturePath: path);
    logger.info(
      'Disk-space watchdog re-targeted to capturePath=$path after a '
      'capture-directory settings change',
      source: _headlessLogSource,
    );
  });

  final subscription = guard.events.listen(
    (event) async {
      switch (event.severity) {
        case DiskSpaceSeverity.blocking:
          logger.critical(
            '[disk-watchdog] BLOCKING: ${event.message} — '
            'commanding sequencer to stop.',
            source: _headlessLogSource,
          );
          try {
            final backend = container.read(sequencerBackendProvider);
            // A disk-full abort is nobody's press: the origin keeps the
            // executor from recording (unsilenceably) 'Operator: stop' on
            // an appliance where nobody is at the keyboard.
            await backend.sequencerStop(origin: 'disk-watchdog');
            logger.info(
              '[disk-watchdog] Sequencer stop command issued successfully',
              source: _headlessLogSource,
            );
          } catch (e, st) {
            logger.error(
              '[disk-watchdog] Sequencer stop failed: $e\n$st — '
              'the next exposure will likely write a truncated FITS frame '
              'before the OS fails the write outright.',
              source: _headlessLogSource,
            );
          }
          break;
        case DiskSpaceSeverity.warning:
          logger.warning(
            '[disk-watchdog] ${event.message}',
            source: _headlessLogSource,
          );
          break;
        case DiskSpaceSeverity.info:
          logger.info(
            '[disk-watchdog] ${event.message}',
            source: _headlessLogSource,
          );
          break;
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      logger.error(
        '[disk-watchdog] Event stream error: $error\n$stackTrace',
        source: _headlessLogSource,
      );
    },
  );

  return subscription;
}
