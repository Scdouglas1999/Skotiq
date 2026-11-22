import 'dart:io';

import 'package:skotiq_core/providers.dart' show AppVersionInfo;

/// Which start the options belong to: the desktop window or the headless host.
enum LaunchMode { desktop, headless }

const _both = {LaunchMode.desktop, LaunchMode.headless};
const _desktop = {LaunchMode.desktop};
const _headless = {LaunchMode.headless};

/// Every command-line option either start reads, with the environment variable
/// that stands in for it. A flag that is not here is refused before the app
/// opens a window, a database or a device.
enum LaunchOption {
  help('--help', summary: 'Print this help and exit.', modes: _both),
  version('--version', summary: 'Print the version and exit.', modes: _both),
  headless(
    '--headless',
    summary: 'Run as a host with no window (also SKOTIQ_HEADLESS=1).',
    modes: _both,
    env: 'SKOTIQ_HEADLESS',
  ),
  serve(
    '--serve',
    optionalValue: true,
    summary: 'Own the equipment and turn remote access on for this run.',
    modes: _desktop,
    env: 'SKOTIQ_SERVE',
    fixesRole: true,
  ),
  master(
    '--master',
    optionalValue: true,
    summary: 'Same as --serve.',
    modes: _desktop,
    fixesRole: true,
  ),
  remoteHostAddress(
    '--remote-host',
    value: 'host',
    summary: 'Drive the host at this address instead of local equipment.',
    modes: _desktop,
    env: 'SKOTIQ_REMOTE_HOST',
    fixesRole: true,
  ),
  remotePort(
    '--remote-port',
    value: 'port',
    summary: 'Port of the remote host.',
    modes: _desktop,
    env: 'SKOTIQ_REMOTE_PORT',
    fixesRole: true,
  ),
  remoteToken(
    '--remote-token',
    value: 'token',
    summary: 'Access token for the remote host.',
    modes: _desktop,
    env: 'SKOTIQ_REMOTE_TOKEN',
    fixesRole: true,
  ),
  remoteScheme(
    '--remote-scheme',
    value: 'http|https',
    summary: 'Scheme of the remote host (default http).',
    modes: _desktop,
    env: 'SKOTIQ_REMOTE_SCHEME',
    fixesRole: true,
  ),
  relaunchedFrom(
    '--relaunched-from',
    value: 'pid',
    summary: 'The process this start replaces.',
    modes: _desktop,
    hidden: true,
    fixesRole: true,
  ),
  port(
    '--port',
    value: 'port',
    summary: 'Server port (also SKOTIQ_PORT).',
    modes: _headless,
    env: 'SKOTIQ_PORT',
  ),
  authToken(
    '--auth-token',
    value: 'token',
    summary: 'Admin access token.',
    modes: _headless,
    env: 'SKOTIQ_AUTH_TOKEN',
  ),
  viewToken(
    '--view-token',
    value: 'token',
    summary: 'Read-only token.',
    modes: _headless,
    env: 'SKOTIQ_VIEW_TOKEN',
  ),
  controlToken(
    '--control-token',
    value: 'token',
    summary: 'Imaging-control token.',
    modes: _headless,
    env: 'SKOTIQ_CONTROL_TOKEN',
  ),
  scopedToken(
    '--scoped-token',
    value: 'token=grants',
    summary: 'Token with per-resource grants; may be repeated.',
    modes: _headless,
    env: 'SKOTIQ_SCOPED_TOKEN',
  ),
  requireAuth(
    '--require-auth',
    summary: 'Generate a random access token.',
    modes: _headless,
  ),
  allowUnauthenticated(
    '--allow-unauthenticated',
    summary: 'Serve every endpoint without a token. Unsafe.',
    modes: _headless,
    env: 'SKOTIQ_ALLOW_UNAUTHENTICATED',
  ),
  allowUnauthenticatedLan(
    '--allow-unauthenticated-lan',
    summary: 'Bind to the LAN without a token. Unsafe.',
    modes: _headless,
    env: 'SKOTIQ_ALLOW_UNAUTHENTICATED_LAN',
  ),
  corsOrigin(
    '--cors-origin',
    value: 'origin',
    summary: 'Allow another web origin; may be repeated.',
    modes: _headless,
    env: 'SKOTIQ_CORS_ORIGINS',
  ),
  pairingPrintCodes(
    '--pairing-print-codes',
    summary: 'Print each pairing code to stdout.',
    modes: _headless,
    env: 'SKOTIQ_PAIRING_PRINT_CODES',
  ),
  tls(
    '--tls',
    summary: 'Serve HTTPS with a self-signed certificate.',
    modes: _headless,
    env: 'SKOTIQ_TLS',
  ),
  tlsCert(
    '--tls-cert',
    value: 'path',
    summary: 'Certificate PEM to serve HTTPS with.',
    modes: _headless,
    env: 'SKOTIQ_TLS_CERT',
  ),
  tlsKey(
    '--tls-key',
    value: 'path',
    summary: 'Private key PEM for --tls-cert.',
    modes: _headless,
    env: 'SKOTIQ_TLS_KEY',
  ),
  relayUrl(
    '--relay-url',
    value: 'url',
    summary: 'Dial out to a Skotiq relay (ws:// or wss://).',
    modes: _headless,
    env: 'SKOTIQ_RELAY_URL',
  ),
  relayAllowInsecureTls(
    '--relay-allow-insecure-tls',
    summary: "Trust the relay's self-signed certificate.",
    modes: _headless,
    env: 'SKOTIQ_RELAY_ALLOW_INSECURE_TLS',
  );

  const LaunchOption(
    this.flag, {
    required this.summary,
    required this.modes,
    this.value,
    this.optionalValue = false,
    this.hidden = false,
    this.env,
    this.fixesRole = false,
  });

  /// The option as typed, with its leading dashes.
  final String flag;

  /// What the value stands for in the usage text (`--port=<port>`), or null
  /// for a switch.
  final String? value;

  /// True when the switch also takes `=value` (`--serve=true`).
  final bool optionalValue;

  final String summary;
  final Set<LaunchMode> modes;

  /// Set by the app itself between its own processes; left out of the usage.
  final bool hidden;

  /// The environment variable that sets the same thing, if there is one.
  final String? env;

  /// True when the option picks the desktop's role (host, linked client). A
  /// relaunch that changes role drops these and blanks their [env].
  final bool fixesRole;

  /// The option [arg] spells, with its value: `--port=80` is (port, '80'),
  /// `--tls` is (tls, null). Null for anything else, which includes a value
  /// option typed without `=value` and a plain switch typed with one.
  static ({LaunchOption option, String? value})? read(String arg) {
    final equals = arg.indexOf('=');
    final flag = equals < 0 ? arg : arg.substring(0, equals);
    for (final option in values) {
      if (option.flag != flag) continue;
      if (equals < 0) {
        return option.value == null ? (option: option, value: null) : null;
      }
      if (option.value == null && !option.optionalValue) return null;
      return (option: option, value: arg.substring(equals + 1));
    }
    return null;
  }

  /// True when [arg] is this option, with or without a value.
  bool matches(String arg) => arg == flag || arg.startsWith('$flag=');

  /// The values given to this option in [args], in order.
  Iterable<String> valuesIn(List<String> args) sync* {
    final prefix = '$flag=';
    for (final arg in args) {
      if (arg.startsWith(prefix)) yield arg.substring(prefix.length);
    }
  }
}

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

const _portOptions = {LaunchOption.port, LaunchOption.remotePort};

/// Reads [args] for a [mode] start. `--help` wins over everything, then
/// `--version`; any argument the [mode] does not take is a usage error.
LaunchRequest readLaunchArguments(List<String> args, LaunchMode mode) {
  if (args.contains(LaunchOption.help.flag)) return const ShowHelp();
  if (args.contains(LaunchOption.version.flag)) return const ShowVersion();
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
  for (final candidate in LaunchOption.values) {
    if (candidate.flag == name) option = candidate;
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
  if (_portOptions.contains(option)) {
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
    for (final option in LaunchOption.values) {
      if (option.hidden || !include(option)) continue;
      final spelled = option.value == null
          ? option.flag
          : '${option.flag}=<${option.value}>';
      buffer.writeln('  ${spelled.padRight(30)} ${option.summary}');
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
