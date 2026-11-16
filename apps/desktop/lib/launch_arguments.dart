import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:skotiq_core/providers.dart' show AppVersionInfo;

import 'desktop_relaunch.dart' show relaunchedFromFlag;

/// Which start the options belong to: the desktop window or the headless host.
enum LaunchMode { desktop, headless }

/// One command-line option the app understands.
@immutable
class LaunchOption {
  const LaunchOption(
    this.name, {
    required this.help,
    required this.modes,
    this.value,
    this.optionalValue = false,
    this.hidden = false,
  });

  /// The option as typed, with its leading dashes.
  final String name;

  /// What the value stands for in the usage text (`--port=<port>`), or null
  /// for a switch.
  final String? value;

  /// True when the switch also takes `=value` (`--serve=true`).
  final bool optionalValue;

  final String help;
  final Set<LaunchMode> modes;

  /// Set by the app itself between its own processes; left out of the usage.
  final bool hidden;
}

const _both = {LaunchMode.desktop, LaunchMode.headless};
const _desktop = {LaunchMode.desktop};
const _headless = {LaunchMode.headless};

/// Every option either start reads. A flag that is not here is refused before
/// the app opens a window, a database or a device.
const launchOptions = <LaunchOption>[
  LaunchOption('--help', help: 'Print this help and exit.', modes: _both),
  LaunchOption('--version', help: 'Print the version and exit.', modes: _both),
  LaunchOption(
    '--headless',
    help: 'Run as a host with no window (also SKOTIQ_HEADLESS=1).',
    modes: _both,
  ),
  LaunchOption(
    '--serve',
    optionalValue: true,
    help: 'Own the equipment and turn remote access on for this run.',
    modes: _desktop,
  ),
  LaunchOption(
    '--master',
    optionalValue: true,
    help: 'Same as --serve.',
    modes: _desktop,
  ),
  LaunchOption(
    '--remote-host',
    value: 'host',
    help: 'Drive the host at this address instead of local equipment.',
    modes: _desktop,
  ),
  LaunchOption(
    '--remote-port',
    value: 'port',
    help: 'Port of the remote host.',
    modes: _desktop,
  ),
  LaunchOption(
    '--remote-token',
    value: 'token',
    help: 'Access token for the remote host.',
    modes: _desktop,
  ),
  LaunchOption(
    '--remote-scheme',
    value: 'http|https',
    help: 'Scheme of the remote host (default http).',
    modes: _desktop,
  ),
  LaunchOption(
    relaunchedFromFlag,
    value: 'pid',
    help: 'The process this start replaces.',
    modes: _desktop,
    hidden: true,
  ),
  LaunchOption(
    '--port',
    value: 'port',
    help: 'Server port (also SKOTIQ_PORT).',
    modes: _headless,
  ),
  LaunchOption(
    '--auth-token',
    value: 'token',
    help: 'Admin access token.',
    modes: _headless,
  ),
  LaunchOption(
    '--view-token',
    value: 'token',
    help: 'Read-only token.',
    modes: _headless,
  ),
  LaunchOption(
    '--control-token',
    value: 'token',
    help: 'Imaging-control token.',
    modes: _headless,
  ),
  LaunchOption(
    '--scoped-token',
    value: 'token=grants',
    help: 'Token with per-resource grants; may be repeated.',
    modes: _headless,
  ),
  LaunchOption(
    '--require-auth',
    help: 'Generate a random access token.',
    modes: _headless,
  ),
  LaunchOption(
    '--allow-unauthenticated',
    help: 'Serve every endpoint without a token. Unsafe.',
    modes: _headless,
  ),
  LaunchOption(
    '--allow-unauthenticated-lan',
    help: 'Bind to the LAN without a token. Unsafe.',
    modes: _headless,
  ),
  LaunchOption(
    '--cors-origin',
    value: 'origin',
    help: 'Allow another web origin; may be repeated.',
    modes: _headless,
  ),
  LaunchOption(
    '--pairing-print-codes',
    help: 'Print each pairing code to stdout.',
    modes: _headless,
  ),
  LaunchOption(
    '--tls',
    help: 'Serve HTTPS with a self-signed certificate.',
    modes: _headless,
  ),
  LaunchOption(
    '--tls-cert',
    value: 'path',
    help: 'Certificate PEM to serve HTTPS with.',
    modes: _headless,
  ),
  LaunchOption(
    '--tls-key',
    value: 'path',
    help: 'Private key PEM for --tls-cert.',
    modes: _headless,
  ),
  LaunchOption(
    '--relay-url',
    value: 'url',
    help: 'Dial out to a Skotiq relay (ws:// or wss://).',
    modes: _headless,
  ),
  LaunchOption(
    '--relay-allow-insecure-tls',
    help: "Trust the relay's self-signed certificate.",
    modes: _headless,
  ),
];

/// What the command line asks for.
sealed class LaunchRequest {
  const LaunchRequest();
}

final class ShowHelp extends LaunchRequest {
  const ShowHelp();
}

final class ShowVersion extends LaunchRequest {
  const ShowVersion();
}

final class LaunchUsageError extends LaunchRequest {
  const LaunchUsageError(this.message);
  final String message;
}

final class StartApp extends LaunchRequest {
  const StartApp();
}

const _portOptions = {'--port', '--remote-port'};

/// Reads [args] for a [mode] start. `--help` wins over everything, then
/// `--version`; any argument the [mode] does not take is a usage error.
LaunchRequest readLaunchArguments(List<String> args, LaunchMode mode) {
  if (args.contains('--help')) return const ShowHelp();
  if (args.contains('--version')) return const ShowVersion();
  for (final arg in args) {
    final error = _checkArgument(arg, mode);
    if (error != null) return LaunchUsageError(error);
  }
  return const StartApp();
}

String? _checkArgument(String arg, LaunchMode mode) {
  final equals = arg.indexOf('=');
  final name = equals < 0 ? arg : arg.substring(0, equals);
  final value = equals < 0 ? null : arg.substring(equals + 1);
  LaunchOption? option;
  for (final candidate in launchOptions) {
    if (candidate.name == name) option = candidate;
  }
  if (option == null) return 'unknown option "$arg"';
  if (!option.modes.contains(mode)) {
    return mode == LaunchMode.headless
        ? '$name is not an option for --headless'
        : '$name works only with --headless';
  }
  if (option.value == null) {
    if (value != null && !option.optionalValue) {
      return '$name takes no value';
    }
    return null;
  }
  if (value == null) return '$name needs a value: $name=<${option.value}>';
  if (_portOptions.contains(name)) {
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) {
      return '$name needs a port number from 1 to 65535, not "$value"';
    }
  }
  return null;
}

/// The usage text `--help` prints and a usage error repeats.
String launchUsage() {
  final buffer = StringBuffer()
    ..writeln('Usage: skotiq [options]')
    ..writeln('       skotiq --headless [host options]');
  void section(String title, bool Function(LaunchOption) include) {
    buffer
      ..writeln()
      ..writeln(title);
    for (final option in launchOptions) {
      if (option.hidden || !include(option)) continue;
      final spelled = option.value == null
          ? option.name
          : '${option.name}=<${option.value}>';
      buffer.writeln('  ${spelled.padRight(30)} ${option.help}');
    }
  }

  section('Options:', (o) => o.modes.length == 2);
  section(
    'Desktop options:',
    (o) => o.modes.length == 1 && o.modes.contains(LaunchMode.desktop),
  );
  section(
    'Host options (with --headless):',
    (o) => o.modes.length == 1 && o.modes.contains(LaunchMode.headless),
  );
  return buffer.toString();
}

/// Answers `--help`, `--version` and a mistyped command line, then ends the
/// process; returns only when the app should start. Runs before any start-up
/// work, so none of these touches the database, the data folder or a device.
///
/// It ends with exit(), not a return: native plugins registered before Dart
/// ran keep the isolate alive.
Future<void> answerLaunchArguments(
  List<String> args,
  LaunchMode mode, {
  required Future<AppVersionInfo> Function() version,
}) async {
  switch (readLaunchArguments(args, mode)) {
    case ShowHelp():
      stdout.write(launchUsage());
      await stdout.flush();
      exit(0);
    case ShowVersion():
      final info = await version();
      stdout.writeln('Skotiq ${info.version} (build ${info.buildNumber})');
      await stdout.flush();
      exit(0);
    case LaunchUsageError(:final message):
      stderr
        ..writeln('skotiq: $message')
        ..writeln()
        ..write(launchUsage());
      await stderr.flush();
      exit(2);
    case StartApp():
      return;
  }
}
