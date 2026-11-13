import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:skotiq_app/skotiq_app.dart' show ShellExit;
import 'package:skotiq_core/providers.dart' show AppRelauncher;
import 'package:window_manager/window_manager.dart';

/// Flag a relaunched process receives: the pid it replaces. The new process
/// waits for that one to release the database before opening a window.
const relaunchedFromFlag = '--relaunched-from';

/// Flags and variables that fix the role at launch. A relaunch that changes
/// role drops all of them, so the choice the store now records takes effect:
/// a linked client started with `SKOTIQ_REMOTE_HOST` must be able to become
/// this computer's host, and a host started with `SKOTIQ_SERVE=1` must be able
/// to link without tripping the serve-and-link conflict.
const _roleFlags = [
  '--remote-host',
  '--remote-port',
  '--remote-token',
  '--remote-scheme',
  '--serve',
  '--master',
  relaunchedFromFlag,
];
const _roleEnvironment = [
  'SKOTIQ_REMOTE_HOST',
  'SKOTIQ_REMOTE_PORT',
  'SKOTIQ_REMOTE_TOKEN',
  'SKOTIQ_REMOTE_SCHEME',
  'SKOTIQ_SERVE',
];

/// [args] without any role flag or a previous [relaunchedFromFlag].
@visibleForTesting
List<String> argumentsWithoutRole(List<String> args) => [
  for (final arg in args)
    if (!_roleFlags.any((flag) => arg == flag || arg.startsWith('$flag=')))
      arg,
];

@visibleForTesting
List<String> relaunchArguments(List<String> args, int currentPid) => [
  ...argumentsWithoutRole(args),
  '$relaunchedFromFlag=$currentPid',
];

/// Environment overrides for the next process: every role variable blanked.
/// `main` treats an empty value as unset.
@visibleForTesting
Map<String, String> relaunchEnvironment() => {
  for (final key in _roleEnvironment) key: '',
};

/// The pid named by [relaunchedFromFlag], or null for an ordinary launch.
int? relaunchedFromPid(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('$relaunchedFromFlag=')) {
      return int.tryParse(arg.substring(relaunchedFromFlag.length + 1));
    }
  }
  return null;
}

/// Restarts the desktop app through the normal window close.
///
/// The close goes through the shell's own quit path, so its confirmation
/// (a run in progress, unsaved edits) still applies and the session record is
/// marked clean. Only once the close is accepted is the next process started,
/// detached, with [relaunchArguments]; it waits for this process to let go of
/// the database ([waitForPreviousInstance]).
class DesktopAppRelauncher implements AppRelauncher {
  DesktopAppRelauncher({
    required List<String> launchArguments,
    void Function(String message)? log,
  }) : _args = List.unmodifiable(launchArguments),
       _log = log {
    ShellExit.registerRelaunch(_spawn);
  }

  final List<String> _args;
  final void Function(String message)? _log;

  Future<void> _spawn() async {
    final executable = Platform.resolvedExecutable;
    final args = relaunchArguments(_args, pid);
    _log?.call('Restarting: $executable ${args.join(' ')}');
    await Process.start(
      executable,
      args,
      mode: ProcessStartMode.detached,
      environment: relaunchEnvironment(),
      workingDirectory: Directory.current.path,
    );
  }

  @override
  Future<bool> relaunch({required String reason}) async {
    _log?.call('Restart requested: $reason');
    final accepted = ShellExit.requestRelaunch();
    await windowManager.close();
    return accepted.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        ShellExit.cancelPendingRelaunch();
        return false;
      },
    );
  }
}

/// Whether [pid] is still running. POSIX only (a harmless SIGCONT probe);
/// on Windows the single-instance lock is the only signal, so this says no.
bool processStillRunning(int pid) {
  if (Platform.isWindows) return false;
  try {
    return Process.killPid(pid, ProcessSignal.sigcont);
  } catch (e) {
    debugPrint('probing pid $pid failed, treating it as gone: $e');
    return false;
  }
}

/// A relaunched process starts while the previous one is still closing. Wait
/// (up to [timeout]) for [isHeld] to report the single-instance lock free.
Future<bool> waitForPreviousInstance(
  Future<bool> Function() isHeld, {
  Duration timeout = const Duration(seconds: 45),
  Duration interval = const Duration(milliseconds: 300),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (await isHeld()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(interval);
  }
  return true;
}
