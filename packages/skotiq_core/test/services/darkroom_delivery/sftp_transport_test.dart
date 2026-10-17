// SFTP delivery drives the OpenSSH command-line tools, so what is testable
// without an SSH server is the decisions: which tool is required, which
// credential is refused, whether the host key is pinned before any byte
// moves, and that the upload goes to a temporary name that is verified before
// it is renamed.
//
// Every test here scripts the command runner. None of them proves the
// transport works against a real sshd — that is validation this suite cannot
// perform and does not claim. `sftp_real_sshd_test.dart` does, against a
// userland OpenSSH server, and the two are complementary: the scripted runner
// can produce failures a real server will not produce on demand.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/darkroom/delivery.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/artifact_transport.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_artifact.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_failure.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_naming.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/sftp_command_runner.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/sftp_transport.dart';
import 'package:skotiq_core/src/services/notification/secrets_store.dart';
import 'package:path/path.dart' as p;

/// One recorded invocation.
class _Invocation {
  _Invocation(this.executable, this.args, this.stdinText);

  final String executable;
  final List<String> args;
  final String? stdinText;

  /// The whole command line, for order and content assertions.
  String get line => '$executable ${args.join(' ')} ${stdinText ?? ''}'.trim();
}

/// A runner the test scripts by predicate.
class _ScriptedRunner implements SftpCommandRunner {
  _ScriptedRunner({this.missingTools = const {}});

  final Set<String> missingTools;
  final List<_Invocation> calls = [];
  final List<({bool Function(_Invocation) when, SftpCommandResult result})>
  rules = [];
  SftpCommandResult fallback = const SftpCommandResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  void when(
    bool Function(_Invocation) predicate, {
    int exitCode = 0,
    String stdout = '',
    String stderr = '',
  }) {
    rules.add((
      when: predicate,
      result: SftpCommandResult(
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
      ),
    ));
  }

  @override
  Future<bool> isAvailable(String executable) async =>
      !missingTools.contains(executable);

  @override
  Future<SftpCommandResult> run(
    String executable,
    List<String> args, {
    required Duration timeout,
    String? stdinText,
  }) async {
    final call = _Invocation(executable, args, stdinText);
    calls.add(call);
    for (final rule in rules) {
      if (rule.when(call)) return rule.result;
    }
    return fallback;
  }
}

/// A host-key line shaped like `ssh-keyscan` output, plus the fingerprint
/// OpenSSH would print for it and the `<algorithm> <key>` pair a destination
/// row stores.
({String line, String fingerprint, String storedKey}) hostKeyLine(String seed) {
  final blob = utf8.encode('ssh-ed25519-key-material-$seed');
  final encoded = base64.encode(blob);
  final digest = base64.encode(sha256.convert(blob).bytes).replaceAll('=', '');
  return (
    line: 'office.local ssh-ed25519 $encoded',
    fingerprint: 'SHA256:$digest',
    storedKey: 'ssh-ed25519 $encoded',
  );
}

void main() {
  late Directory tempDir;
  late SecretsStore secrets;
  late InMemorySecureKeyValueStore keyring;
  late List<HostKeyScanEntry> pinned;

  const secretRef = 'delivery.office_pc_key';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_sftp_test_');
    keyring = InMemorySecureKeyValueStore();
    secrets = SecretsStore(keyring);
    await secrets.write(secretRef, '-----BEGIN OPENSSH PRIVATE KEY-----');
    pinned = [];
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ArtifactDestination destination({
    String? fingerprint,
    String? storedKey,
    String? authMethod,
    String? ref = secretRef,
    String? digestCommand,
    // Delivered names carry a rig-identity component whose default is this
    // machine's host name. Pinned to "" here — deliver under the rig's own
    // file names — so the asserted OpenSSH command lines describe the wire and
    // not the machine the suite runs on. The component has its own coverage in
    // delivery_naming_test.dart and against the real sshd.
    String rigId = '',
  }) {
    return ArtifactDestination(
      id: 9,
      name: 'office-pc',
      kind: ArtifactDestinationKind.sftp,
      configJson: jsonEncode(<String, Object?>{
        'host': 'office.local',
        'port': 2222,
        'user': 'sean',
        'remoteDir': '/srv/astro/incoming',
        kDeliveryRigIdKey: rigId,
        if (fingerprint != null) 'hostKeyFingerprint': fingerprint,
        if (storedKey != null) 'hostKey': storedKey,
        if (authMethod != null) 'authMethod': authMethod,
        if (digestCommand != null) 'digestCommand': digestCommand,
      }),
      enabled: true,
      content: const {ArtifactContent.linearMasters},
      secretRef: ref,
      createdAt: DateTime.utc(2026, 8, 16),
      updatedAt: DateTime.utc(2026, 8, 16),
    );
  }

  SftpTransport transport(
    _ScriptedRunner runner, {
    ArtifactDestination? target,
  }) {
    return SftpTransport(
      destination: target ?? destination(),
      jobId: 12,
      secrets: secrets,
      runner: runner,
      pinHostKey: (key) async => pinned.add(key),
    );
  }

  Future<DeliveryFile> master() async {
    final file = File(p.join(tempDir.path, 'M31_Ha_master.fits'));
    await file.writeAsString('MASTER');
    return DeliveryFile.describe(file.path);
  }

  group('preflight refusals', () {
    test('a machine with no OpenSSH client says so instead of failing at the '
        'first upload', () async {
      final runner = _ScriptedRunner(missingTools: {'sftp'});

      await expectLater(
        transport(runner).open([await master()]),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.transportToolMissing,
              )
              .having((f) => f.message, 'message', contains('sftp')),
        ),
      );
    });

    test('a password-configured destination names the substitute rather than '
        'hanging on a prompt', () async {
      final runner = _ScriptedRunner();

      await expectLater(
        transport(
          runner,
          target: destination(authMethod: 'password'),
        ).open([await master()]),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.authMethodUnavailable,
              )
              .having((f) => f.message, 'message', contains('private key')),
        ),
      );
      expect(runner.calls, isEmpty);
    });

    test('a destination with no secret_ref is a credential failure', () async {
      final runner = _ScriptedRunner();

      await expectLater(
        transport(
          runner,
          target: destination(ref: null),
        ).open([await master()]),
        throwsA(
          isA<DeliveryFailure>().having(
            (f) => f.kind,
            'kind',
            DeliveryFailureKind.credentialMissing,
          ),
        ),
      );
    });

    test(
      'a secret_ref the keyring does not hold is a credential failure',
      () async {
        final runner = _ScriptedRunner();

        await expectLater(
          transport(
            runner,
            target: destination(ref: 'delivery.never_stored'),
          ).open([await master()]),
          throwsA(
            isA<DeliveryFailure>().having(
              (f) => f.kind,
              'kind',
              DeliveryFailureKind.credentialMissing,
            ),
          ),
        );
      },
    );
  });

  group('host key pinning', () {
    test('pins the key on first use and writes a known-hosts file for the '
        'session', () async {
      final key = hostKeyLine('first');
      final runner = _ScriptedRunner();
      runner.when(
        (c) => c.executable == 'ssh-keyscan',
        stdout: '# office.local:2222 SSH-2.0\n${key.line}\n',
      );

      final t = transport(runner);
      await t.open([await master()]);

      expect(pinned.single.fingerprint, key.fingerprint);
      expect(
        pinned.single.knownHostsKey,
        key.storedKey,
        reason: 'the key itself is stored, so later deliveries need no scan',
      );
      final sshCall = runner.calls.firstWhere((c) => c.executable == 'ssh');
      final knownHostsOption = sshCall.args.firstWhere(
        (a) => a.startsWith('UserKnownHostsFile='),
      );
      final knownHosts = File(
        knownHostsOption.substring('UserKnownHostsFile='.length),
      );
      expect(
        await knownHosts.readAsString(),
        '$kSftpHostKeyAlias ${key.storedKey}\n',
      );
      expect(sshCall.args, contains('StrictHostKeyChecking=yes'));
      expect(sshCall.args, contains('BatchMode=yes'));
      await t.close();
    });

    test('a server presenting a different key is refused and nothing is '
        'uploaded', () async {
      final pinnedKey = hostKeyLine('pinned');
      final impostor = hostKeyLine('impostor');
      final runner = _ScriptedRunner();
      runner.when(
        (c) => c.executable == 'ssh-keyscan',
        stdout: '${impostor.line}\n',
      );

      await expectLater(
        transport(
          runner,
          target: destination(fingerprint: pinnedKey.fingerprint),
        ).open([await master()]),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.hostKeyMismatch,
              )
              .having((f) => f.retryable, 'retryable', isFalse)
              .having(
                (f) => f.message,
                'message',
                contains('nothing was sent'),
              ),
        ),
      );
      expect(
        runner.calls.where((c) => c.executable == 'sftp'),
        isEmpty,
        reason: 'the mismatch is decided before any transfer starts',
      );
      expect(pinned, isEmpty, reason: 'a mismatch never re-pins');
    });

    test(
      'key material does not outlive an open that failed',
      () async {
        final pinnedKey = hostKeyLine('pinned');
        final impostor = hostKeyLine('impostor');
        final runner = _ScriptedRunner();
        runner.when(
          (c) => c.executable == 'ssh-keyscan',
          stdout: '${impostor.line}\n',
        );

        await expectLater(
          transport(
            runner,
            target: destination(fingerprint: pinnedKey.fingerprint),
          ).open([await master()]),
          throwsA(isA<DeliveryFailure>()),
        );

        final chmod = runner.calls.firstWhere((c) => c.executable == 'chmod');
        final keyFile = File(chmod.args.last);
        expect(
          await keyFile.exists(),
          isFalse,
          reason: 'the private key is removed when the attempt fails',
        );
        expect(await keyFile.parent.exists(), isFalse);
      },
      skip: Platform.isWindows ? 'chmod is a POSIX-only step' : null,
    );

    test(
      'a host that presents no key at all is unreachable, not trusted',
      () async {
        final runner = _ScriptedRunner();
        runner.when(
          (c) => c.executable == 'ssh-keyscan',
          exitCode: 1,
          stderr: 'office.local: Connection refused',
        );

        await expectLater(
          transport(runner).open([await master()]),
          throwsA(
            isA<DeliveryFailure>().having(
              (f) => f.kind,
              'kind',
              DeliveryFailureKind.destinationUnreachable,
            ),
          ),
        );
        expect(pinned, isEmpty);
      },
    );

    test(
      'an already-pinned key is matched among several the server offers',
      () async {
        final rsa = hostKeyLine('rsa');
        final ed = hostKeyLine('ed25519');
        final runner = _ScriptedRunner();
        runner.when(
          (c) => c.executable == 'ssh-keyscan',
          stdout: '${rsa.line}\n${ed.line}\n',
        );

        final t = transport(
          runner,
          target: destination(fingerprint: ed.fingerprint),
        );
        await t.open([await master()]);

        expect(
          pinned.single.fingerprint,
          ed.fingerprint,
          reason:
              'the trusted fingerprint is unchanged — what is written is '
              'the key behind it, so the next delivery needs no scan',
        );
        await t.close();
      },
    );

    test(
      'a destination that already stores its key makes no scan at all',
      () async {
        final key = hostKeyLine('stored');
        final runner = _ScriptedRunner();

        final t = transport(
          runner,
          target: destination(
            fingerprint: key.fingerprint,
            storedKey: key.storedKey,
          ),
        );
        await t.open([await master()]);

        expect(
          runner.calls.where((c) => c.executable == 'ssh-keyscan'),
          isEmpty,
        );
        expect(pinned, isEmpty);
        await t.close();
      },
    );

    test('a stored key that does not match the stored fingerprint is refused '
        'rather than half-trusted', () async {
      final key = hostKeyLine('stored');
      final other = hostKeyLine('other');
      final runner = _ScriptedRunner();

      await expectLater(
        transport(
          runner,
          target: destination(
            fingerprint: other.fingerprint,
            storedKey: key.storedKey,
          ),
        ).open([await master()]),
        throwsA(
          isA<DeliveryFailure>().having(
            (f) => f.kind,
            'kind',
            DeliveryFailureKind.configurationInvalid,
          ),
        ),
      );
      expect(runner.calls, isEmpty);
    });
  });

  group('delivering a file', () {
    late _ScriptedRunner runner;
    late String digest;

    Future<SftpTransport> opened({String? fingerprint}) async {
      final key = hostKeyLine('happy');
      runner.when(
        (c) => c.executable == 'ssh-keyscan',
        stdout: '${key.line}\n',
      );
      final t = transport(
        runner,
        target: destination(fingerprint: fingerprint),
      );
      await t.open([await master()]);
      return t;
    }

    setUp(() async {
      runner = _ScriptedRunner();
      digest = (await master()).checksum;
    });

    test('uploads to a temporary name, verifies it, then renames it into '
        'place — in that order', () async {
      runner.when(
        (c) => c.executable == 'ssh' && c.args.contains('-e'),
        exitCode: 1,
      );
      runner.when(
        (c) => c.executable == 'ssh' && c.args.contains('sha256sum'),
        stdout:
            '$digest  /srv/astro/incoming/.M31_Ha_master.fits.12'
            '.skdelivery-part\n',
      );
      final t = await opened();

      final outcome = await t.deliver(await master());
      await t.close();

      final sftpCalls = runner.calls
          .where((c) => c.executable == 'sftp')
          .toList();
      expect(sftpCalls.length, 2);
      expect(sftpCalls[0].stdinText, startsWith('put '));
      expect(sftpCalls[0].stdinText, contains('.skdelivery-part'));
      expect(
        sftpCalls[0].stdinText,
        isNot(contains("'/srv/astro/incoming/M31_Ha_master.fits'")),
      );
      expect(sftpCalls[1].stdinText, startsWith('rename '));
      expect(
        sftpCalls[1].stdinText,
        contains("'/srv/astro/incoming/M31_Ha_master.fits'"),
      );

      final verifyIndex = runner.calls.indexWhere(
        (c) => c.executable == 'ssh' && c.args.contains('sha256sum'),
      );
      final renameIndex = runner.calls.indexWhere(
        (c) => c.stdinText?.startsWith('rename ') ?? false,
      );
      expect(
        verifyIndex,
        lessThan(renameIndex),
        reason: 'the checksum is proved before the final name exists',
      );
      expect(outcome.disposition, DeliveryDisposition.delivered);
      expect(outcome.checksum, digest);
      expect(outcome.destinationDescription, contains('sean@office.local'));
    });

    test(
      'a remote copy that hashes differently is removed and reported',
      () async {
        runner.when(
          (c) => c.executable == 'ssh' && c.args.contains('-e'),
          exitCode: 1,
        );
        runner.when(
          (c) => c.executable == 'ssh' && c.args.contains('sha256sum'),
          stdout: '${'de' * 32}  remote-temp\n',
        );
        final t = await opened();

        await expectLater(
          t.deliver(await master()),
          throwsA(
            isA<DeliveryFailure>().having(
              (f) => f.kind,
              'kind',
              DeliveryFailureKind.checksumMismatch,
            ),
          ),
        );
        expect(
          runner.calls.any((c) => c.stdinText?.startsWith('rm ') ?? false),
          isTrue,
          reason: 'the unverified temporary is cleaned up',
        );
        expect(
          runner.calls.any((c) => c.stdinText?.startsWith('rename ') ?? false),
          isFalse,
          reason: 'nothing that failed verification is renamed into place',
        );
        await t.close();
      },
    );

    test('a server with no SHA-256 command is a tool failure, not a silent '
        'skip of verification', () async {
      runner.when(
        (c) => c.executable == 'ssh' && c.args.contains('-e'),
        exitCode: 1,
      );
      runner.when(
        (c) =>
            c.executable == 'ssh' &&
            (c.args.contains('sha256sum') || c.args.contains('shasum -a 256')),
        exitCode: 127,
        stderr: 'sha256sum: command not found',
      );
      final t = await opened();

      await expectLater(
        t.deliver(await master()),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.transportToolMissing,
              )
              .having((f) => f.message, 'message', contains('SHA-256')),
        ),
      );
      expect(
        runner.calls.any((c) => c.stdinText?.startsWith('rename ') ?? false),
        isFalse,
      );
      await t.close();
    });

    test('falls back to shasum when sha256sum is absent', () async {
      runner.when(
        (c) => c.executable == 'ssh' && c.args.contains('-e'),
        exitCode: 1,
      );
      runner.when(
        (c) => c.executable == 'ssh' && c.args.contains('sha256sum'),
        exitCode: 127,
        stderr: 'sha256sum: command not found',
      );
      runner.when(
        (c) => c.executable == 'ssh' && c.args.contains('shasum -a 256'),
        stdout: '$digest  remote-temp\n',
      );
      final t = await opened();

      final outcome = await t.deliver(await master());

      expect(outcome.checksum, digest);
      await t.close();
    });

    test('a file already there with different bytes is a conflict, never an '
        'overwrite', () async {
      runner.when(
        (c) => c.executable == 'ssh' && c.args.contains('-e'),
        exitCode: 0,
      );
      runner.when(
        (c) => c.executable == 'ssh' && c.args.contains('sha256sum'),
        stdout: '${'ab' * 32}  remote-final\n',
      );
      final t = await opened();

      await expectLater(
        t.deliver(await master()),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.destinationConflict,
              )
              .having((f) => f.retryable, 'retryable', isFalse),
        ),
      );
      expect(runner.calls.where((c) => c.executable == 'sftp'), isEmpty);
      await t.close();
    });

    test(
      'the same bytes already there is a delivery, not a second upload',
      () async {
        runner.when(
          (c) => c.executable == 'ssh' && c.args.contains('-e'),
          exitCode: 0,
        );
        runner.when(
          (c) => c.executable == 'ssh' && c.args.contains('sha256sum'),
          stdout: '$digest  remote-final\n',
        );
        final t = await opened();

        final outcome = await t.deliver(await master());

        expect(outcome.disposition, DeliveryDisposition.delivered);
        expect(runner.calls.where((c) => c.executable == 'sftp'), isEmpty);
        await t.close();
      },
    );

    test('an upload that fails leaves nothing under the final name', () async {
      runner.when(
        (c) => c.executable == 'ssh' && c.args.contains('-e'),
        exitCode: 1,
      );
      runner.when(
        (c) =>
            c.executable == 'sftp' &&
            (c.stdinText?.startsWith('put ') ?? false),
        exitCode: 1,
        stderr: 'Connection closed',
      );
      final t = await opened();

      await expectLater(
        t.deliver(await master()),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.transportFailure,
              )
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      expect(
        runner.calls.any((c) => c.stdinText?.startsWith('rename ') ?? false),
        isFalse,
      );
      await t.close();
    });

    test('releases the private key file when the session closes', () async {
      final t = await opened();
      final keyOption = runner.calls
          .firstWhere((c) => c.executable == 'ssh')
          .args
          .elementAt(
            runner.calls
                    .firstWhere((c) => c.executable == 'ssh')
                    .args
                    .indexOf('-i') +
                1,
          );
      expect(await File(keyOption).exists(), isTrue);

      await t.close();

      expect(
        await File(keyOption).exists(),
        isFalse,
        reason: 'the key material does not outlive the delivery',
      );
    });
  });

  group('remote path safety', () {
    test(
      'a remote directory carrying a quote is refused rather than escaped',
      () async {
        final runner = _ScriptedRunner();
        final target = ArtifactDestination(
          id: 9,
          name: 'office-pc',
          kind: ArtifactDestinationKind.sftp,
          configJson: jsonEncode(<String, Object?>{
            'host': 'office.local',
            'user': 'sean',
            'remoteDir': "/srv/astro/'; rm -rf /",
          }),
          enabled: true,
          content: const {ArtifactContent.linearMasters},
          secretRef: secretRef,
          createdAt: DateTime.utc(2026, 8, 16),
          updatedAt: DateTime.utc(2026, 8, 16),
        );

        await expectLater(
          transport(runner, target: target).open([await master()]),
          throwsA(
            isA<DeliveryFailure>().having(
              (f) => f.kind,
              'kind',
              DeliveryFailureKind.configurationInvalid,
            ),
          ),
        );
      },
    );
  });

  group('parsing ssh-keyscan output', () {
    test('computes the fingerprint OpenSSH would print', () {
      final key = hostKeyLine('parse');

      final entries = parseHostKeyScan('${key.line}\n');

      expect(entries.single.fingerprint, key.fingerprint);
      expect(entries.single.knownHostsKey, key.storedKey);
    });

    test('ignores comment lines and unparseable rows', () {
      final key = hostKeyLine('parse');

      final entries = parseHostKeyScan(
        '# a comment\n'
        'short line\n'
        'office.local ssh-rsa not-base-64!!\n'
        '${key.line}\n',
      );

      expect(entries.length, 1);
      expect(entries.single.fingerprint, key.fingerprint);
    });
  });
}
