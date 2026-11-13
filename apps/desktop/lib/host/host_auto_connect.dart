import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import 'host_startup.dart';

const _logSource = 'HostAutoConnect';

/// Connects the start-up profile's equipment, when "Auto-connect equipment"
/// is on. Runs once per launch on the process that owns the hardware; a
/// linked client never runs it, so opening a client cannot move the host's
/// devices.
///
/// Nothing here can stop the host: equipment that is offline, or a local
/// backend that never became ready, is reported and start-up goes on, so the
/// rig stays reachable for someone to fix it. The daemon reports on stderr
/// for an operator tailing the console; the GUI raises a toast.
Future<void> hostAutoConnect({
  required ProviderContainer container,
  required LoggingService logger,
  HostKind kind = HostKind.daemon,
  Future<void>? backendReady,
}) async {
  if (backendReady != null) {
    try {
      await backendReady;
    } catch (error, stack) {
      logger.error(
        'Local backend readiness failed; Skotiq keeps running so you can '
        'recover — startup auto-connect skipped: $error',
        source: _logSource,
        fields: {'error': error.toString(), 'stack': stack.toString()},
      );
      _report(
        container,
        kind,
        'Equipment was not connected at startup: the local backend did not '
        'start ($error).',
      );
      return;
    }
  }

  try {
    final backend = container.read(backendProvider);
    if (!backend.ownsDeviceBridge) {
      // A host always owns local hardware; if it somehow does not, skip
      // rather than drive someone else's rig.
      logger.warning(
        'Startup auto-connect skipped: the drivers are not loaded in this '
        'process (${backend.runtimeType})',
        source: _logSource,
      );
      return;
    }

    await container.read(profileServiceProvider).autoConnectOnStartup();
    logger.info('Startup auto-connect completed', source: _logSource);
  } catch (error, stack) {
    logger.error(
      'Startup auto-connect failed; Skotiq keeps running so you can '
      'recover: $error',
      source: _logSource,
      fields: {'error': error.toString(), 'stack': stack.toString()},
    );
    _report(
      container,
      kind,
      error is ProfileAutoConnectException
          ? 'Some equipment did not connect on startup: '
                '${error.described.join('; ')}'
          : 'Equipment auto-connect failed on startup: $error',
    );
  }
}

void _report(ProviderContainer container, HostKind kind, String message) {
  switch (kind) {
    case HostKind.daemon:
      stderr.writeln('Skotiq: $message');
    case HostKind.gui:
      container
          .read(uiNotificationProvider.notifier)
          .showError(message, title: 'Equipment auto-connect');
  }
}
