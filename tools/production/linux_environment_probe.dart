import 'dart:convert';
import 'dart:io';

const _jsonOutputPath =
    'docs/production-readiness/linux-environment-probe.json';
const _markdownOutputPath =
    'docs/production-readiness/linux-environment-probe.md';

void main(List<String> args) async {
  final requireLinux = args.contains('--require-linux');

  final checks = <_CommandCheck>[
    await _runCommand(
      id: 'wsl_status',
      command: 'wsl.exe',
      arguments: ['--status'],
      requiredForLinuxBuild: false,
    ),
    await _runCommand(
      id: 'wsl_list',
      command: 'wsl.exe',
      arguments: ['-l', '-v'],
      requiredForLinuxBuild: false,
    ),
    await _runCommand(
      id: 'wsl_ubuntu_uname',
      command: 'wsl.exe',
      arguments: ['-d', 'Ubuntu', '--', 'uname', '-a'],
      requiredForLinuxBuild: true,
    ),
    await _runCommand(
      id: 'docker_version',
      command: 'docker',
      arguments: ['version'],
      requiredForLinuxBuild: false,
    ),
    await _runCommand(
      id: 'docker_context_ls',
      command: 'docker',
      arguments: ['context', 'ls'],
      requiredForLinuxBuild: false,
    ),
  ];

  final wslUsable = checks
      .where((check) => check.id == 'wsl_ubuntu_uname')
      .every((check) => check.exitCode == 0);
  final dockerUsable = checks
      .where((check) => check.id == 'docker_version')
      .every((check) => check.exitCode == 0);
  final linuxBuildEnvironmentAvailable = wslUsable || dockerUsable;

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'hostPlatform': Platform.operatingSystem,
    'linuxBuildEnvironmentAvailable': linuxBuildEnvironmentAvailable,
    'wslUsable': wslUsable,
    'dockerUsable': dockerUsable,
    'note':
        'This probes whether this host can run Linux build verification. It does not build Skotiq for Linux.',
    'checks': checks.map((check) => check.toJson()).toList(),
  };

  await File(
    _jsonOutputPath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(_markdownOutputPath).writeAsString(
    _renderMarkdown(
      linuxBuildEnvironmentAvailable: linuxBuildEnvironmentAvailable,
      wslUsable: wslUsable,
      dockerUsable: dockerUsable,
      checks: checks,
    ),
  );

  stdout.writeln('Linux environment probe complete.');
  stdout.writeln(
    'Linux build environment available: $linuxBuildEnvironmentAvailable',
  );
  stdout.writeln('WSL usable: $wslUsable');
  stdout.writeln('Docker usable: $dockerUsable');
  stdout.writeln('JSON: $_jsonOutputPath');
  stdout.writeln('Markdown: $_markdownOutputPath');

  if (requireLinux && !linuxBuildEnvironmentAvailable) {
    exit(1);
  }
}

Future<_CommandCheck> _runCommand({
  required String id,
  required String command,
  required List<String> arguments,
  required bool requiredForLinuxBuild,
}) async {
  final started = DateTime.now();
  try {
    final result = await Process.run(
      command,
      arguments,
      runInShell: Platform.isWindows,
    ).timeout(const Duration(seconds: 30));
    return _CommandCheck(
      id: id,
      command: [command, ...arguments].join(' '),
      exitCode: result.exitCode,
      stdout: _decodeOutput(result.stdout),
      stderr: _decodeOutput(result.stderr),
      durationMs: DateTime.now().difference(started).inMilliseconds,
      requiredForLinuxBuild: requiredForLinuxBuild,
    );
  } catch (error) {
    return _CommandCheck(
      id: id,
      command: [command, ...arguments].join(' '),
      exitCode: -1,
      stdout: '',
      stderr: error.toString(),
      durationMs: DateTime.now().difference(started).inMilliseconds,
      requiredForLinuxBuild: requiredForLinuxBuild,
    );
  }
}

String _decodeOutput(Object? value) {
  final text = value?.toString() ?? '';
  return text.replaceAll('\u0000', '').trim();
}

String _renderMarkdown({
  required bool linuxBuildEnvironmentAvailable,
  required bool wslUsable,
  required bool dockerUsable,
  required List<_CommandCheck> checks,
}) {
  final buffer = StringBuffer()
    ..writeln('# Linux Environment Probe')
    ..writeln()
    ..writeln(
      '- Linux build environment available: `$linuxBuildEnvironmentAvailable`',
    )
    ..writeln('- WSL usable: `$wslUsable`')
    ..writeln('- Docker usable: `$dockerUsable`')
    ..writeln(
      '- Scope: host environment only; this does not build Skotiq for Linux.',
    )
    ..writeln()
    ..writeln('## Command Results')
    ..writeln()
    ..writeln('| Check | Exit | Required | Command |')
    ..writeln('| --- | ---: | --- | --- |');

  for (final check in checks) {
    buffer.writeln(
      '| `${check.id}` | ${check.exitCode} | '
      '${check.requiredForLinuxBuild ? 'yes' : 'no'} | '
      '`${check.command}` |',
    );
  }

  buffer.writeln();
  for (final check in checks) {
    buffer
      ..writeln('## `${check.id}`')
      ..writeln()
      ..writeln('Exit code: `${check.exitCode}`')
      ..writeln()
      ..writeln('Stdout:')
      ..writeln()
      ..writeln('```text')
      ..writeln(_truncate(check.stdout))
      ..writeln('```')
      ..writeln()
      ..writeln('Stderr:')
      ..writeln()
      ..writeln('```text')
      ..writeln(_truncate(check.stderr))
      ..writeln('```')
      ..writeln();
  }

  return buffer.toString();
}

String _truncate(String text, {int maxChars = 4000}) {
  if (text.length <= maxChars) return text;
  return '${text.substring(0, maxChars)}\n... truncated ...';
}

class _CommandCheck {
  final String id;
  final String command;
  final int exitCode;
  final String stdout;
  final String stderr;
  final int durationMs;
  final bool requiredForLinuxBuild;

  const _CommandCheck({
    required this.id,
    required this.command,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.durationMs,
    required this.requiredForLinuxBuild,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'command': command,
    'exitCode': exitCode,
    'stdout': stdout,
    'stderr': stderr,
    'durationMs': durationMs,
    'requiredForLinuxBuild': requiredForLinuxBuild,
  };
}
