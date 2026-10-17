/// The process-invocation seam the SFTP transport drives OpenSSH through.
///
/// Skotiq has no SFTP client dependency — the repository contains no SSH
/// library at all — and hand-rolling SSH cryptography is not on the table. The
/// transport therefore drives the OpenSSH command-line tools the way
/// [PlateSolveService] drives a local solver: `Process.start`, a retained
/// handle so a timeout can actually kill the child, and a typed failure when
/// the binary is absent.
///
/// The seam exists so the transport's decisions — pin the host key, upload to
/// a staged name, verify the remote digest, rename — are unit-testable
/// without an SSH server. The tests substitute a scripted runner; production
/// passes [ProcessSftpCommandRunner].
library;

import 'dart:async';
import 'dart:io';

/// One finished external-command run.
class SftpCommandResult {
  /// Process exit status.
  final int exitCode;

  /// Everything the command wrote to stdout, decoded with the system
  /// encoding.
  final String stdout;

  /// Everything the command wrote to stderr, decoded with the system
  /// encoding.
  final String stderr;

  const SftpCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// True when the command reported success.
  bool get succeeded => exitCode == 0;

  /// The stderr text trimmed to one line for a failure message, falling back
  /// to stdout when the tool writes its diagnostics there.
  String get diagnostic {
    final text = stderr.trim().isNotEmpty ? stderr.trim() : stdout.trim();
    final firstLine = text.split('\n').first.trim();
    return firstLine.isEmpty ? 'exit status $exitCode' : firstLine;
  }
}

/// The external commands the SFTP transport runs.
abstract class SftpCommandRunner {
  /// Run [executable] with [args], optionally feeding [stdinText] to its
  /// standard input, and wait at most [timeout].
  ///
  /// A timeout kills the child before returning, so an `sftp` that is blocked
  /// on an unreachable host cannot outlive the delivery attempt and write into
  /// the destination after the journal has already recorded a failure.
  Future<SftpCommandResult> run(
    String executable,
    List<String> args, {
    required Duration timeout,
    String? stdinText,
  });

  /// Whether [executable] resolves on this machine's PATH.
  Future<bool> isAvailable(String executable);
}

/// [SftpCommandRunner] backed by real child processes.
class ProcessSftpCommandRunner implements SftpCommandRunner {
  const ProcessSftpCommandRunner();

  @override
  Future<SftpCommandResult> run(
    String executable,
    List<String> args, {
    required Duration timeout,
    String? stdinText,
  }) async {
    final process = await Process.start(executable, args);
    if (stdinText != null) {
      process.stdin.write(stdinText);
    }
    await process.stdin.close();

    final stdoutFuture = systemEncoding.decodeStream(process.stdout);
    final stderrFuture = systemEncoding.decodeStream(process.stderr);

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      try {
        exitCode = await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        exitCode = await process.exitCode;
      }
      return SftpCommandResult(
        exitCode: exitCode,
        stdout: await stdoutFuture,
        stderr:
            '$executable did not finish within ${timeout.inSeconds}s and was '
            'terminated',
      );
    }

    return SftpCommandResult(
      exitCode: exitCode,
      stdout: await stdoutFuture,
      stderr: await stderrFuture,
    );
  }

  @override
  Future<bool> isAvailable(String executable) async {
    final locator = Platform.isWindows ? 'where' : 'which';
    try {
      final result = await Process.run(locator, [executable]);
      return result.exitCode == 0;
    } on ProcessException {
      // The locator itself is missing, which is the same practical answer for
      // the caller: this machine cannot be shown to have the tool.
      return false;
    }
  }
}
