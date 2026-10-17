// The SFTP transport against a REAL OpenSSH server.
//
// `sftp_transport_test.dart` scripts the command runner: it proves the
// transport's decisions — pin before transfer, stage before rename, verify
// before rename — without an SSH server, and it says so. What it cannot prove
// is that OpenSSH behaves the way those scripts assume. This file closes that
// gap by starting a userland `sshd` on loopback (see
// `test/harness/real_sshd_server.dart`) and running the production
// [ProcessSftpCommandRunner] against it, then reading the result off the
// server's own filesystem.
//
// Facts this file pinned down that no scripted runner could, each of which
// changed the transport:
//
//   * `ssh-keyscan` opens SIX connections per invocation and authenticates on
//     none of them. An sshd built after 9.8 penalises exactly that, and three
//     scans is enough for it to start dropping the client — good key and all.
//     So the learned key is stored and the scan happens once per destination,
//     not once per delivery.
//   * A server the key is not authorised for answers `Permission denied
//     (publickey)` with SSH's own exit status 255, not with the remote
//     command's. Read as "the directory did not answer" that became a
//     RETRYABLE unreachable-destination — a wrong key retried forever, which
//     is the very thing that earns the source penalty above.
//   * SFTP `rename` is a POSIX rename: it REPLACES the destination file
//     silently. "Delivery never overwrites" therefore rests entirely on the
//     existence check before the upload, so a check that fails to answer now
//     stops the delivery instead of reading as an empty destination.
//   * A server with a login banner sends it on STDERR before anything else,
//     so at OpenSSH's default log level every failure message quoted the
//     banner instead of the failure.
//
// The tests skip themselves — with the missing binary named — on a machine
// with no OpenSSH server. They never fail for want of one.
@Tags(['real-sshd'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/darkroom/delivery.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/artifact_transport.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/atomic_file_write.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_artifact.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_failure.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_naming.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/sftp_command_runner.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/sftp_transport.dart';
import 'package:skotiq_core/src/services/notification/secrets_store.dart';
import 'package:path/path.dart' as p;

import '../../harness/real_sshd_server.dart';

/// The production runner, with a record of what was actually run.
///
/// Every command still reaches a real process — the recording is what lets a
/// test assert that a scan did NOT happen, or that nothing was uploaded.
class _RecordingRunner implements SftpCommandRunner {
  final List<String> executables = [];
  final List<String> batches = [];
  final SftpCommandRunner _delegate = const ProcessSftpCommandRunner();

  int countOf(String executable) =>
      executables.where((e) => e == executable).length;

  @override
  Future<bool> isAvailable(String executable) =>
      _delegate.isAvailable(executable);

  @override
  Future<SftpCommandResult> run(
    String executable,
    List<String> args, {
    required Duration timeout,
    String? stdinText,
  }) {
    executables.add(executable);
    if (stdinText != null) batches.add(stdinText.trim());
    return _delegate.run(
      executable,
      args,
      timeout: timeout,
      stdinText: stdinText,
    );
  }
}

void main() {
  final skipReason = RealSshdServer.unavailableReason();

  group('SFTP delivery against a real sshd', () {
    late RealSshdServer server;
    late Directory rigDir;
    late SecretsStore secrets;
    late List<HostKeyScanEntry> pinned;
    late _RecordingRunner runner;

    const secretRef = 'delivery.real_sshd_key';
    const fileName = 'M31_Ha_master.fits';
    const fileBody =
        'SIMPLE  =                    T / real bytes over a wire\n';

    setUp(() async {
      server = await RealSshdServer.start();
      rigDir = await Directory.systemTemp.createTemp('ns_rig_');
      secrets = SecretsStore(InMemorySecureKeyValueStore());
      await secrets.write(secretRef, server.authorizedPrivateKey);
      pinned = [];
      runner = _RecordingRunner();
    });

    tearDown(() async {
      await server.dispose();
      if (await rigDir.exists()) await rigDir.delete(recursive: true);
    });

    /// A destination row pointing at the fixture server.
    ///
    /// [hostKeyFingerprint] and [hostKey] are the two halves of the pin, given
    /// separately so a test can stand a row up in the state a first delivery
    /// leaves it in — or in the fingerprint-only state a row written by an
    /// earlier build is in.
    ArtifactDestination destination({
      String? remoteDir,
      String? hostKeyFingerprint,
      String? hostKey,
      String? secret = secretRef,
      // See sftp_transport_test.dart: pinned to the rig's own file names so
      // the assertions describe the bytes on the server rather than this
      // machine's host name. One test below pins a real component instead.
      String rigId = '',
    }) {
      return ArtifactDestination(
        id: 7,
        name: 'office-pc',
        kind: ArtifactDestinationKind.sftp,
        configJson: jsonEncode(<String, Object?>{
          'host': '127.0.0.1',
          'port': server.port,
          'user': server.user,
          'remoteDir': remoteDir ?? server.incomingDir.path,
          kDeliveryRigIdKey: rigId,
          if (hostKeyFingerprint != null)
            'hostKeyFingerprint': hostKeyFingerprint,
          if (hostKey != null) 'hostKey': hostKey,
        }),
        enabled: true,
        content: const {ArtifactContent.linearMasters},
        secretRef: secret,
        createdAt: DateTime.utc(2026, 8, 16),
        updatedAt: DateTime.utc(2026, 8, 16),
      );
    }

    SftpTransport transport(ArtifactDestination target) => SftpTransport(
      destination: target,
      jobId: 41,
      secrets: secrets,
      runner: runner,
      pinHostKey: (key) async => pinned.add(key),
    );

    /// A master on the rig, hashed the way delivery hashes it.
    Future<DeliveryFile> master({String body = fileBody}) async {
      final file = File(p.join(rigDir.path, fileName));
      await file.writeAsString(body);
      return DeliveryFile.describe(file.path);
    }

    /// What is on the server, by name.
    Future<List<String>> remoteNames() async {
      final entries = await server.incomingDir.list().toList();
      return entries.map((e) => p.basename(e.path)).toList()..sort();
    }

    test('first use pins the server key, then stages, verifies and renames a '
        'real file into place', () async {
      final artifact = await master();
      final t = transport(destination());

      await t.open([artifact]);
      final outcome = await t.deliver(artifact);
      await t.close();

      // The pin is the server's own key, and the fingerprint the transport
      // computes is the one `ssh-keygen -l` prints for it. That is the check
      // that keeps an operator's out-of-band comparison meaningful.
      expect(pinned, hasLength(1));
      expect(pinned.single.fingerprint, server.hostKeyFingerprint);
      expect(pinned.single.knownHostsKey, server.hostKeyEntry);

      // The bytes are on the server, under the final name, and nothing is left
      // staged.
      expect(await remoteNames(), [fileName]);
      final landed = File(p.join(server.incomingDir.path, fileName));
      expect(await landed.readAsString(), fileBody);
      expect(outcome.disposition, DeliveryDisposition.delivered);
      expect(outcome.checksum, artifact.checksum);
      expect(
        outcome.destinationDescription,
        '${server.user}@127.0.0.1:${p.join(server.incomingDir.path, fileName)}',
      );

      // Staged first, verified, and only then renamed — read off the commands
      // that really ran.
      expect(runner.batches.first, startsWith('put '));
      expect(runner.batches.first, contains(kStagedDeliverySuffix));
      expect(runner.batches.last, startsWith('rename '));

      // The source is untouched: delivery copies.
      expect(await File(artifact.sourcePath).readAsString(), fileBody);
    });

    test(
      'a pinned destination delivers without scanning the server again',
      () async {
        final artifact = await master();
        final t = transport(
          destination(
            hostKeyFingerprint: server.hostKeyFingerprint,
            hostKey: server.hostKeyEntry,
          ),
        );

        await t.open([artifact]);
        await t.deliver(artifact);
        await t.close();

        expect(
          runner.countOf('ssh-keyscan'),
          0,
          reason:
              'a scan is six unauthenticated connections, and an sshd built '
              'after 9.8 penalises a source for making them',
        );
        expect(pinned, isEmpty, reason: 'an existing pin is not rewritten');
        expect(await remoteNames(), [fileName]);
      },
    );

    test('a server presenting a different key than the pinned one is refused '
        'and nothing is delivered', () async {
      final artifact = await master();
      final target = destination(
        hostKeyFingerprint: server.hostKeyFingerprint,
        hostKey: server.hostKeyEntry,
      );
      // The server is rebuilt with a new identity while the pin still names
      // the old one — a rebuilt box, or someone in the middle.
      await server.restartWithNewHostKey();

      await expectLater(
        transport(target).open([artifact]),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.hostKeyMismatch,
              )
              .having((f) => f.retryable, 'retryable', isFalse),
        ),
      );
      expect(await remoteNames(), isEmpty);
      expect(runner.countOf('sftp'), 0);
    });

    test('a destination pinned by fingerprint alone still catches a changed '
        'key at the scan', () async {
      final artifact = await master();
      final target = destination(hostKeyFingerprint: server.hostKeyFingerprint);
      await server.restartWithNewHostKey();

      await expectLater(
        transport(target).open([artifact]),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.hostKeyMismatch,
              )
              .having(
                (f) => f.message,
                'message',
                contains('nothing was sent'),
              ),
        ),
      );
      expect(await remoteNames(), isEmpty);
      expect(pinned, isEmpty, reason: 'a mismatch never re-pins');
    });

    test('a key the server will not take is a terminal refusal, not an '
        'unreachable destination', () async {
      await secrets.write(secretRef, server.unauthorizedPrivateKey);
      final artifact = await master();

      await expectLater(
        transport(destination()).open([artifact]),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.permissionDenied,
              )
              .having((f) => f.retryable, 'retryable', isFalse)
              .having(
                (f) => f.message,
                'message',
                contains('Permission denied'),
              ),
        ),
      );
      expect(await remoteNames(), isEmpty);
    });

    test(
      'a refusal names the refusal, not the server\'s login banner',
      () async {
        await server.dispose();
        server = await RealSshdServer.start(
          banner: 'AUTHORIZED USE ONLY. All activity is logged.',
        );
        await secrets.write(secretRef, server.unauthorizedPrivateKey);
        final artifact = await master();

        await expectLater(
          transport(destination()).open([artifact]),
          throwsA(
            isA<DeliveryFailure>()
                .having(
                  (f) => f.message,
                  'message',
                  contains('Permission denied'),
                )
                .having(
                  (f) => f.message,
                  'message',
                  isNot(contains('AUTHORIZED USE ONLY')),
                ),
          ),
        );
      },
    );

    test('a remote directory that is not there is retryable, and says which '
        'directory', () async {
      final artifact = await master();
      final missing = p.join(server.root.path, 'not_mounted', 'incoming');

      await expectLater(
        transport(destination(remoteDir: missing)).open([artifact]),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.destinationUnreachable,
              )
              .having((f) => f.retryable, 'retryable', isTrue)
              .having((f) => f.message, 'message', contains(missing)),
        ),
      );
      expect(runner.countOf('sftp'), 0);
    });

    test('delivering the same bytes twice is one upload and one delivered '
        'verdict', () async {
      final artifact = await master();
      final target = destination(
        hostKeyFingerprint: server.hostKeyFingerprint,
        hostKey: server.hostKeyEntry,
      );

      final first = transport(target);
      await first.open([artifact]);
      await first.deliver(artifact);
      await first.close();
      final uploads = runner.countOf('sftp');

      final second = transport(target);
      await second.open([artifact]);
      final outcome = await second.deliver(artifact);
      await second.close();

      expect(outcome.disposition, DeliveryDisposition.delivered);
      expect(outcome.checksum, artifact.checksum);
      expect(
        runner.countOf('sftp'),
        uploads,
        reason: 'the file already there with the right hash is not sent again',
      );
      expect(await remoteNames(), [fileName]);
      expect(
        await File(p.join(server.incomingDir.path, fileName)).readAsString(),
        fileBody,
      );
    });

    test('a different file under a name already on the server is a conflict, '
        'and the bytes there survive it', () async {
      final target = destination(
        hostKeyFingerprint: server.hostKeyFingerprint,
        hostKey: server.hostKeyEntry,
      );
      final first = transport(target);
      final original = await master();
      await first.open([original]);
      await first.deliver(original);
      await first.close();

      // The same name, different content — a second night's master written
      // over the top of the first is exactly what delivery must refuse.
      final reprocessed = await master(body: 'SIMPLE  = T / different bytes\n');
      final second = transport(target);
      await second.open([reprocessed]);

      await expectLater(
        second.deliver(reprocessed),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.destinationConflict,
              )
              .having((f) => f.retryable, 'retryable', isFalse)
              .having((f) => f.message, 'message', contains(original.checksum)),
        ),
      );
      await second.close();

      expect(
        await File(p.join(server.incomingDir.path, fileName)).readAsString(),
        fileBody,
        reason:
            'SFTP rename replaces silently, so a conflict must be decided '
            'before anything is uploaded',
      );
      expect(await remoteNames(), [fileName]);
    });

    test(
      'two rigs uploading the same file name into one incoming directory '
      'both land, because the delivered name says which rig wrote it',
      () async {
        // The previous test is what a SECOND RIG used to hit: the same name is
        // already on the server with different bytes, so its night was refused
        // terminally and never arrived. A rig-identity component on the
        // delivered name is what keeps both nights.
        final shed = destination(
          hostKeyFingerprint: server.hostKeyFingerprint,
          hostKey: server.hostKeyEntry,
          rigId: 'shed-rig',
        );
        final roof = destination(
          hostKeyFingerprint: server.hostKeyFingerprint,
          hostKey: server.hostKeyEntry,
          rigId: 'roof-rig',
        );

        final shedTransport = transport(shed);
        final shedMaster = await master();
        await shedTransport.open([shedMaster]);
        final shedOutcome = await shedTransport.deliver(shedMaster);
        await shedTransport.close();

        const roofBody = 'SIMPLE  = T / the other rig\'s night\n';
        final roofMaster = await master(body: roofBody);
        final roofTransport = transport(roof);
        await roofTransport.open([roofMaster]);
        final roofOutcome = await roofTransport.deliver(roofMaster);
        await roofTransport.close();

        expect(shedOutcome.disposition, DeliveryDisposition.delivered);
        expect(roofOutcome.disposition, DeliveryDisposition.delivered);
        expect(await remoteNames(), [
          'roof-rig-$fileName',
          'shed-rig-$fileName',
        ]);
        expect(
          await File(
            p.join(server.incomingDir.path, 'roof-rig-$fileName'),
          ).readAsString(),
          roofBody,
          reason: 'the second rig\'s night is on the server, not refused',
        );
      },
    );

    test('a server that goes away mid-job stops the delivery instead of '
        'uploading over an answer it does not have', () async {
      final artifact = await master();
      final t = transport(
        destination(
          hostKeyFingerprint: server.hostKeyFingerprint,
          hostKey: server.hostKeyEntry,
        ),
      );
      await t.open([artifact]);
      await server.stop();

      await expectLater(
        t.deliver(artifact),
        throwsA(
          isA<DeliveryFailure>()
              .having((f) => f.retryable, 'retryable', isTrue)
              .having(
                (f) => f.message,
                'message',
                contains('could not be determined'),
              ),
        ),
      );
      expect(
        runner.batches.where((b) => b.startsWith('put ')),
        isEmpty,
        reason: 'nothing is uploaded while the destination is unreadable',
      );
      await t.close();
    });

    test('the private key does not outlive the session', () async {
      final artifact = await master();
      final t = transport(destination());
      await t.open([artifact]);

      final keyDirs = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('ns_sftp_'))
          .toList();
      expect(keyDirs, isNotEmpty);
      final keyFile = File(p.join(keyDirs.first.path, 'id_delivery'));
      expect(await keyFile.exists(), isTrue);
      expect(
        (await keyFile.stat()).mode & 0x1FF,
        0x180,
        reason: 'OpenSSH refuses a private key any other account can read',
      );

      await t.close();

      expect(await keyFile.exists(), isFalse);
      expect(await keyFile.parent.exists(), isFalse);
    });
  }, skip: skipReason);
}
