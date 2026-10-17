/// Owner-only persistence for the small credential files Skotiq keeps in
/// the application-support directory.
///
/// Two of those files — `remote_access_token.txt` (the persistent bearer token
/// the embedded API server accepts) and `push_secret.txt` (the LAN-push
/// authentication secret) — were written with `File.writeAsString`, which
/// creates at 0666 masked by the process umask: 0644 in practice. The profile
/// database beside them is 0600, so the two files that ARE credentials were the
/// readable ones. On a shared or multi-user machine any local account could
/// read the token that grants control of the rig.
///
/// The application-support directory is not the protection people assume it is.
/// On Linux it is `$XDG_DATA_HOME/<app>`, created 0755, so "the directory is
/// per-user-private" holds on Windows and macOS but not here.
///
/// [writeSecretFile] closes the window rather than narrowing it: the file is
/// created empty and restricted BEFORE the secret is written into it, so the
/// bytes never exist at a wider mode. [restrictSecretFile] repairs a file an
/// older build already created world-readable.
library;

import 'dart:io';

/// Write [contents] to [file] such that only the owner can read it.
///
/// The order matters. Writing first and restricting after would leave the
/// secret on disk at 0644 for the length of a syscall or two, which is a real
/// window on a machine that has another local account on it. So: create empty,
/// restrict, then write.
Future<void> writeSecretFile(File file, String contents) async {
  await file.parent.create(recursive: true);
  if (!await file.exists()) {
    await file.create();
  }
  await restrictSecretFile(file);
  await file.writeAsString(contents, flush: true);
}

/// Restrict [file] to owner-only (0600) on POSIX.
///
/// Also called for files that already exist, so an install created by an older
/// build stops being world-readable the next time the credential is read.
///
/// Non-fatal: a failure is reported on stderr and does not throw. A rig that
/// cannot chmod its token file must still start — refusing to boot would turn a
/// permissions nit into an outage — but the operator is told.
Future<void> restrictSecretFile(File file) async {
  if (Platform.isWindows) {
    // No portable POSIX chmod on NTFS without icacls. The per-user app-data
    // ACL is the protection there, and unlike the Linux case it genuinely is
    // per-user-private.
    return;
  }
  try {
    final result = await Process.run('chmod', ['600', file.path]);
    if (result.exitCode != 0) {
      stderr.writeln(
        '[secrets] WARNING: chmod 600 ${file.path} failed: ${result.stderr}',
      );
    }
  } catch (error) {
    stderr.writeln(
      '[secrets] WARNING: could not restrict ${file.path}: $error',
    );
  }
}
