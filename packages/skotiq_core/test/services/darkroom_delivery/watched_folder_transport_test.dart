// Watched-folder delivery against real temp directories, plus the fault
// injections a NAS actually produces: the mount disappears, the volume fills,
// the same name is already there with different bytes, and the process dies
// between the staged copy and the rename.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/darkroom/delivery.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/artifact_transport.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/atomic_file_write.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_artifact.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_failure.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_naming.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/watched_folder_transport.dart';
import 'package:path/path.dart' as p;

class _FixedFreeSpace implements FreeSpaceProbe {
  _FixedFreeSpace(this.bytes);

  final int bytes;

  @override
  Future<int> freeBytes(String path) async => bytes;
}

ArtifactDestination _destination({
  required String path,
  int? minFreeBytes,
  Set<ArtifactContent> content = const {ArtifactContent.linearMasters},
  // Delivered names carry a rig-identity component, and the default is this
  // machine's host name. These tests pin it to "" — deliver under the rig's
  // own file names — so every existing assertion still describes the bytes and
  // not the machine the suite happens to run on. The component itself is
  // exercised in delivery_naming_test.dart and in the collision test below.
  String rigId = '',
}) {
  final config = <String, Object?>{
    'path': path,
    kDeliveryRigIdKey: rigId,
    if (minFreeBytes != null) 'minFreeBytes': minFreeBytes,
  };
  return ArtifactDestination(
    id: 3,
    name: 'nas',
    kind: ArtifactDestinationKind.watchedFolder,
    configJson: jsonEncode(config),
    enabled: true,
    content: content,
    createdAt: DateTime.utc(2026, 8, 16),
    updatedAt: DateTime.utc(2026, 8, 16),
  );
}

void main() {
  late Directory tempDir;
  late Directory source;
  late Directory destinationDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_watched_');
    source = await Directory(p.join(tempDir.path, 'source')).create();
    destinationDir = await Directory(p.join(tempDir.path, 'nas')).create();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<DeliveryArtifact> writeMaster(
    String name, {
    String contents = 'MASTER-LIGHT-BYTES',
  }) async {
    final file = File(p.join(source.path, name));
    await file.writeAsString(contents);
    return DeliveryArtifact.describeArtifact(
      content: ArtifactContent.linearMasters,
      path: file.path,
    );
  }

  WatchedFolderTransport transportFor({
    String? path,
    int freeBytes = 1 << 40,
    int? minFreeBytes,
    String rigId = '',
  }) {
    return WatchedFolderTransport(
      destination: _destination(
        path: path ?? destinationDir.path,
        minFreeBytes: minFreeBytes,
        rigId: rigId,
      ),
      jobId: 42,
      freeSpace: _FixedFreeSpace(freeBytes),
    );
  }

  group('delivering into a watched folder', () {
    test(
      'copies the file, leaves the source, and reports where it went',
      () async {
        final artifact = await writeMaster('M31_Ha_master.fits');
        final transport = transportFor();
        await transport.open([artifact]);

        final outcome = await transport.deliver(artifact);
        await transport.close();

        final landed = File(p.join(destinationDir.path, 'M31_Ha_master.fits'));
        expect(outcome.disposition, DeliveryDisposition.delivered);
        expect(outcome.checksum, artifact.checksum);
        expect(outcome.destinationDescription, landed.path);
        expect(await landed.readAsString(), 'MASTER-LIGHT-BYTES');
        expect(
          await File(artifact.sourcePath).exists(),
          isTrue,
          reason: 'delivery copies and never moves',
        );
      },
    );

    test('leaves no staged file behind after a successful delivery', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final transport = transportFor();
      await transport.open([artifact]);
      await transport.deliver(artifact);
      await transport.close();

      final leftovers = destinationDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith(kStagedDeliverySuffix))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('re-delivering the same bytes is a delivery, not a rewrite', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final transport = transportFor();
      await transport.open([artifact]);
      await transport.deliver(artifact);
      final landed = File(p.join(destinationDir.path, 'M31_Ha_master.fits'));
      final firstModified = await landed.lastModified();

      final second = await transport.deliver(artifact);
      await transport.close();

      expect(second.disposition, DeliveryDisposition.delivered);
      expect(second.checksum, artifact.checksum);
      expect(await landed.lastModified(), firstModified);
    });

    test('refuses to overwrite a file that has different content and names '
        'the conflict', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final squatter = File(p.join(destinationDir.path, 'M31_Ha_master.fits'));
      await squatter.writeAsString('SOMEBODY-ELSES-MASTER');
      final transport = transportFor();
      await transport.open([artifact]);

      final failure = await transport
          .deliver(artifact)
          .then<DeliveryFailure?>((_) => null)
          .onError<DeliveryFailure>((error, _) => error);
      await transport.close();

      expect(failure, isNotNull);
      expect(failure!.kind, DeliveryFailureKind.destinationConflict);
      expect(failure.retryable, isFalse);
      expect(failure.message, contains('M31_Ha_master.fits'));
      expect(failure.message, contains(artifact.checksum));
      expect(await squatter.readAsString(), 'SOMEBODY-ELSES-MASTER');
    });

    test('two rigs delivering the same file name into one folder both land, '
        'because the delivered name says which rig wrote it', () async {
      // The shape that cost a night: each rig's job counter starts at 1, so
      // both write `job_1_report.json`, and delivery never overwrites. Before
      // the delivered name carried a rig identity the second rig's file was
      // refused as a `destinationConflict` — terminal, so no later attempt
      // changed it, and the second rig's night simply never arrived.
      final shed = await writeMaster(
        'job_1_report.json',
        contents: 'THE SHED RIG NIGHT',
      );
      final shedTransport = transportFor(rigId: 'shed-rig');
      await shedTransport.open([shed]);
      final shedOutcome = await shedTransport.deliver(shed);
      await shedTransport.close();

      // The second rig writes a file of the SAME name with different bytes.
      final roofSource = await Directory(
        p.join(tempDir.path, 'roof-source'),
      ).create();
      final roofFile = File(p.join(roofSource.path, 'job_1_report.json'));
      await roofFile.writeAsString('THE ROOF RIG NIGHT');
      final roof = await DeliveryArtifact.describeArtifact(
        content: ArtifactContent.linearMasters,
        path: roofFile.path,
      );
      final roofTransport = transportFor(rigId: 'roof-rig');
      await roofTransport.open([roof]);
      final roofOutcome = await roofTransport.deliver(roof);
      await roofTransport.close();

      expect(shedOutcome.disposition, DeliveryDisposition.delivered);
      expect(roofOutcome.disposition, DeliveryDisposition.delivered);
      final shedLanded = File(
        p.join(destinationDir.path, 'shed-rig-job_1_report.json'),
      );
      final roofLanded = File(
        p.join(destinationDir.path, 'roof-rig-job_1_report.json'),
      );
      expect(await shedLanded.readAsString(), 'THE SHED RIG NIGHT');
      expect(
        await roofLanded.readAsString(),
        'THE ROOF RIG NIGHT',
        reason: 'the second rig\'s night is on the share, not refused',
      );
      expect(
        File(p.join(destinationDir.path, 'job_1_report.json')).existsSync(),
        isFalse,
        reason: 'nothing lands under the bare, colliding name',
      );
    });

    test('a folder already holding this rig\'s own delivery is still '
        'idempotent under the namespaced name', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final transport = transportFor(rigId: 'shed-rig');
      await transport.open([artifact]);
      final first = await transport.deliver(artifact);
      final second = await transport.deliver(artifact);
      await transport.close();

      expect(first.disposition, DeliveryDisposition.delivered);
      expect(second.disposition, DeliveryDisposition.delivered);
      expect(
        second.destinationDescription,
        p.join(destinationDir.path, 'shed-rig-M31_Ha_master.fits'),
      );
    });
  });

  group('preflight', () {
    test('reports a destination that is not mounted as unreachable', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final transport = transportFor(
        path: p.join(tempDir.path, 'unmounted-nas'),
      );

      await expectLater(
        transport.open([artifact]),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.destinationUnreachable,
              )
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      expect(
        await Directory(p.join(tempDir.path, 'unmounted-nas')).exists(),
        isFalse,
        reason: 'an unmounted share is never created as a local directory',
      );
    });

    test(
      'refuses a delivery larger than the free space plus headroom',
      () async {
        final artifact = await writeMaster('M31_Ha_master.fits');
        final transport = transportFor(
          freeBytes: artifact.bytes + 10,
          minFreeBytes: 1024,
        );

        await expectLater(
          transport.open([artifact]),
          throwsA(
            isA<DeliveryFailure>()
                .having(
                  (f) => f.kind,
                  'kind',
                  DeliveryFailureKind.insufficientSpace,
                )
                .having((f) => f.retryable, 'retryable', isTrue),
          ),
        );
      },
    );

    test('accepts a delivery that fits inside the free space', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final transport = transportFor(
        freeBytes: artifact.bytes + 4096,
        minFreeBytes: 1024,
      );

      await transport.open([artifact]);
      await transport.close();
    });

    test('a path that holds a FILE says so, and is not retried', () async {
      // A share whose mountpoint was replaced by a stub, or a path typed one
      // component short. `Directory.exists()` is false for it, so it read as
      // "not on the filesystem right now" — about something that plainly is —
      // and was re-attempted every sweep until the budget ran out.
      final asFile = File(p.join(tempDir.path, 'nas-is-a-file'));
      await asFile.writeAsString('not the share');
      final artifact = await writeMaster('M31_Ha_master.fits');

      await expectLater(
        transportFor(path: asFile.path).open([artifact]),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.configurationInvalid,
              )
              .having((f) => f.retryable, 'retryable', isFalse)
              .having((f) => f.message, 'message', contains('is a file'))
              .having(
                (f) => f.message,
                'message',
                isNot(contains('is not on the filesystem')),
              ),
        ),
      );
      expect(
        await asFile.readAsString(),
        'not the share',
        reason: 'delivery never rewrites what it found in its way',
      );
    });

    test('a destination with no path is a configuration failure, not a '
        'silent skip', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final transport = WatchedFolderTransport(
        destination: ArtifactDestination(
          id: 4,
          name: 'unconfigured',
          kind: ArtifactDestinationKind.watchedFolder,
          configJson: '{}',
          enabled: true,
          content: const {ArtifactContent.linearMasters},
          createdAt: DateTime.utc(2026, 8, 16),
          updatedAt: DateTime.utc(2026, 8, 16),
        ),
        jobId: 42,
        freeSpace: _FixedFreeSpace(1 << 40),
      );

      await expectLater(
        transport.open([artifact]),
        throwsA(
          isA<DeliveryFailure>().having(
            (f) => f.kind,
            'kind',
            DeliveryFailureKind.configurationInvalid,
          ),
        ),
      );
    });

    test('delivering before opening is refused rather than writing into a '
        'directory nobody checked', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final transport = transportFor();

      await expectLater(
        transport.deliver(artifact),
        throwsA(isA<DeliveryFailure>()),
      );
    });
  });

  group('atomicity', () {
    test('a process killed between the staged copy and the rename leaves no '
        'file under the final name', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');

      // stage() is the whole of what a delivery does before commit(); dropping
      // the AtomicFileWrite here is exactly what a kill at that instant does.
      final staged = await AtomicFileWrite.stage(
        artifact: artifact,
        deliveredName: artifact.fileName,
        directory: destinationDir,
        jobId: 42,
      );

      expect(
        await File(p.join(destinationDir.path, 'M31_Ha_master.fits')).exists(),
        isFalse,
        reason: 'the final name is only ever created by the rename',
      );
      expect(await File(staged.stagedPath).exists(), isTrue);
      expect(staged.stagedPath, endsWith(kStagedDeliverySuffix));
      expect(staged.stagedChecksum, artifact.checksum);
    });

    test('the staged copy is verified before it is committed', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final lying = DeliveryArtifact(
        content: ArtifactContent.linearMasters,
        sourcePath: artifact.sourcePath,
        bytes: artifact.bytes,
        checksum: 'de' * 32,
      );

      await expectLater(
        AtomicFileWrite.stage(
          artifact: lying,
          deliveredName: lying.fileName,
          directory: destinationDir,
          jobId: 42,
        ),
        throwsA(
          isA<DeliveryFailure>().having(
            (f) => f.kind,
            'kind',
            DeliveryFailureKind.checksumMismatch,
          ),
        ),
      );
      expect(
        destinationDir.listSync(),
        isEmpty,
        reason: 'a copy that did not verify is removed, not left as progress',
      );
    });

    test('a retry of the same job reuses one staged name instead of '
        'accumulating temporaries', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');

      final first = await AtomicFileWrite.stage(
        artifact: artifact,
        deliveredName: artifact.fileName,
        directory: destinationDir,
        jobId: 42,
      );
      final second = await AtomicFileWrite.stage(
        artifact: artifact,
        deliveredName: artifact.fileName,
        directory: destinationDir,
        jobId: 42,
      );

      expect(second.stagedPath, first.stagedPath);
      expect(destinationDir.listSync().length, 1);

      await second.commit();
      expect(
        await File(p.join(destinationDir.path, 'M31_Ha_master.fits')).exists(),
        isTrue,
      );
    });

    test('a source that vanished before delivery is a typed failure', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      await File(artifact.sourcePath).delete();
      final transport = transportFor();
      await transport.open([artifact]);

      await expectLater(
        transport.deliver(artifact),
        throwsA(isA<DeliveryFailure>()),
      );
      expect(
        await File(p.join(destinationDir.path, 'M31_Ha_master.fits')).exists(),
        isFalse,
      );
    });

    // One vanish, one type. A share that drops between the open and the copy
    // is the same event `open` calls `destinationUnreachable` and the same
    // event `destinationReadFailure` calls `destinationUnreachable` for a file
    // it was reading back — but the copy fell through to `transportFailure`,
    // which names no mechanism, so one unmounted NAS reached the journal under
    // two unrelated-looking names depending on which file was where.
    test('a share that drops mid-transfer is unreachable, not an '
        'unclassified transport failure', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final transport = transportFor();
      await transport.open([artifact]);
      await destinationDir.delete(recursive: true);

      await expectLater(
        transport.deliver(artifact),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.destinationUnreachable,
              )
              .having((f) => f.retryable, 'retryable', isTrue)
              .having(
                (f) => f.message,
                'message',
                contains('no longer on the filesystem'),
              ),
        ),
      );
      expect(
        await File(artifact.sourcePath).exists(),
        isTrue,
        reason: 'the artifact never moved; the destination did',
      );
    });

    // The other half of that rule: a claim about the SHARE has to be earned
    // from the share. A drop folder watched by a sync agent that unlinks
    // `.nsdelivery-part` files 0-2 ms after they appear produced
    //   destinationUnreachable: Reading <drop>/.<master>.2.nsdelivery-part
    //   failed: Cannot open file — No such file or directory (errno 2). That
    //   is the destination's copy and <rig>/<master> is still on the rig, so
    //   the destination went away, not the artifact
    // while `ls -d <drop>` answered normally in the same second. The sibling
    // arm, `_copyFailure`, stats the directory before saying that; this one
    // inferred it from the source still existing.
    test('a staged copy deleted under a live directory is not a vanished '
        'share', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final staged = File(
        p.join(
          destinationDir.path,
          '.M31_Ha_master.fits.2$kStagedDeliverySuffix',
        ),
      );

      DeliveryFailure? read;
      try {
        await sha256OfFile(staged);
      } on DeliveryFailure catch (failure) {
        read = failure;
      }
      final typed = await destinationReadFailure(
        sourcePath: artifact.sourcePath,
        destinationFile: staged,
        failure: read!,
      );

      expect(await destinationDir.exists(), isTrue);
      expect(
        typed.message,
        isNot(contains('the destination went away')),
        reason: 'the directory answered; only the staged copy is missing',
      );
      expect(
        typed.message,
        contains(destinationDir.path),
        reason: 'the directory that was stat-ed is named, as _copyFailure does',
      );
      expect(
        typed.message,
        contains(kStagedDeliverySuffix),
        reason: 'what is deleting part files is the operator\'s next question',
      );
      expect(
        typed.retryable,
        isTrue,
        reason: 'the next sweep re-stages this file and delivers it',
      );
    });

    test('a staged copy read under a share that dropped still says the share '
        'went away', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final staged = File(
        p.join(
          destinationDir.path,
          '.M31_Ha_master.fits.2$kStagedDeliverySuffix',
        ),
      );
      await destinationDir.delete(recursive: true);

      DeliveryFailure? read;
      try {
        await sha256OfFile(staged);
      } on DeliveryFailure catch (failure) {
        read = failure;
      }
      final typed = await destinationReadFailure(
        sourcePath: artifact.sourcePath,
        destinationFile: staged,
        failure: read!,
      );

      expect(typed.kind, DeliveryFailureKind.destinationUnreachable);
      expect(typed.message, contains('the destination went away'));
    });

    test('a rename onto a vanished share is unreachable too', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      final staged = await AtomicFileWrite.stage(
        artifact: artifact,
        deliveredName: artifact.fileName,
        directory: destinationDir,
        jobId: 42,
      );
      // The share drops in the instant between staging and committing — the
      // last thing a vanish can break, and the same vanish the sibling files
      // in this transfer are reporting.
      await destinationDir.delete(recursive: true);

      await expectLater(
        staged.commit(),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.destinationUnreachable,
              )
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
    });
  });

  // A failed copy said WHAT it could not do and never WHY. On a drop folder
  // that ran out of inodes the journal, the morning report and the Settings
  // status line all read
  //   insufficientSpace: Copying <master> to <drop> failed: Cannot copy file
  //   to '<drop>/.<master>.1.nsdelivery-part'
  // — a sentence that would be word-for-word identical for a read-only mount,
  // a dead symlink or a name too long for the filesystem. The reason was in
  // hand the whole time: `osError.errorCode == 28` is what picked
  // `insufficientSpace` one line earlier.
  group('the operating system\'s reason', () {
    test('a full destination says "No space left on device", not just that the '
        'copy failed', () {
      // Exactly the exception dart:io raises when File.copy hits ENOSPC: the
      // act in `message`, the reason in `osError`.
      const enospc = FileSystemException(
        "Cannot copy file to '/drop/.M31_Ha_master.fits.1.nsdelivery-part'",
        '/rig/M31_Ha_master.fits',
        OSError('No space left on device', 28),
      );

      final sentence = fileSystemReason(enospc);
      expect(sentence, contains('No space left on device'));
      expect(sentence, contains('errno 28'));
      expect(
        sentence,
        contains("Cannot copy file to '/drop/"),
        reason: 'the file the copy was writing is still named',
      );
    });

    test('an exception with no OS error is reported as it stands', () {
      const bare = FileSystemException('Delivery was cancelled', '/rig/x.fits');
      expect(fileSystemReason(bare), 'Delivery was cancelled');
    });

    test('a real refused copy carries its errno through to the operator '
        'sentence', () async {
      final artifact = await writeMaster('M31_Ha_master.fits');
      // A destination directory that is not there: a genuine OS refusal with a
      // real errno, so this proves the wiring rather than the wording.
      final missing = Directory(p.join(tempDir.path, 'gone', 'deeper'));

      await expectLater(
        AtomicFileWrite.stage(
          artifact: artifact,
          deliveredName: artifact.fileName,
          directory: missing,
          jobId: 7,
        ),
        throwsA(
          isA<DeliveryFailure>().having(
            (f) => f.message,
            'message',
            allOf(
              contains('M31_Ha_master.fits'),
              contains(missing.path),
              contains('errno '),
              // The OS reason, whatever this platform words it as, is present
              // rather than the act alone.
              isNot(endsWith("nsdelivery-part'")),
            ),
          ),
        ),
      );
    });
  });

  group('describing artifacts', () {
    test('a missing source is reported, never skipped', () async {
      await expectLater(
        DeliveryArtifact.describeArtifact(
          content: ArtifactContent.draftRender,
          path: p.join(source.path, 'never-written.jpg'),
        ),
        throwsA(
          isA<DeliveryFailure>().having(
            (f) => f.kind,
            'kind',
            DeliveryFailureKind.sourceMissing,
          ),
        ),
      );
    });

    test('a set selects only what a destination asked for', () async {
      final master = await writeMaster('M31_Ha_master.fits');
      final draft = File(p.join(source.path, 'draft.jpg'));
      await draft.writeAsString('JPEG');

      final set = await DeliveryArtifactSet.build(
        jobId: 42,
        sources: {
          ArtifactContent.linearMasters: [master.sourcePath],
          ArtifactContent.draftRender: [draft.path],
        },
      );

      final mastersOnly = set.selectedFor(
        _destination(
          path: destinationDir.path,
          content: const {ArtifactContent.linearMasters},
        ),
      );
      expect(set.artifacts.length, 2);
      expect(mastersOnly.map((a) => a.fileName), ['M31_Ha_master.fits']);
    });
  });
}
