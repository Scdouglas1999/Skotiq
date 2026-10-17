/// The files one finished dawn job hands to delivery.
///
/// The job produces per-filter linear masters, a draft render, optional
/// per-stage exports and the night report. Delivery copies them; it never
/// moves them, and it never deletes a source. Each file carries the checksum
/// of the bytes ON THE RIG, computed once, so every destination verifies
/// against the same number rather than against whatever it happened to read
/// back.
///
/// Two types, because two callers know different amounts. A fresh job knows
/// which class of artifact each file is and delivers a [DeliveryArtifact]; the
/// overnight retry sweep re-reads a `delivery_journal` row, which records the
/// path but not the class, and delivers a [DeliveryFile]. Transports take the
/// lesser of the two, since the class only ever decides WHICH destinations a
/// file goes to and that decision is already made by the time a transport sees
/// it.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../models/darkroom/delivery.dart';
import 'delivery_failure.dart';

/// One file on the rig, sized and hashed.
class DeliveryFile {
  /// Absolute path of the file on the rig. This is the journal row's identity
  /// (`delivery_journal.file_path`), so it is what a restart re-picks by.
  final String sourcePath;

  /// Size in bytes at the moment the file was described.
  final int bytes;

  /// Lowercase hex SHA-256 of the file's bytes at the moment it was
  /// described.
  final String checksum;

  const DeliveryFile({
    required this.sourcePath,
    required this.bytes,
    required this.checksum,
  });

  /// The file name a destination writes. Delivery preserves the rig's name —
  /// the naming scheme lives upstream in the master writer, and a second
  /// scheme here would make the same master arrive under two names on two
  /// destinations.
  String get fileName => p.basename(sourcePath);

  /// Stat and hash the file at [path].
  ///
  /// A path that is missing or unreadable is a typed failure rather than a
  /// skip: a job whose master vanished between integration and delivery has a
  /// problem the morning report must state, and a silently shorter list would
  /// read as a complete delivery.
  static Future<DeliveryFile> describe(String path) async {
    final file = File(path);
    final length = await confirmOnRig(path);
    return DeliveryFile(
      sourcePath: file.absolute.path,
      bytes: length,
      checksum: await sha256OfFile(file),
    );
  }

  /// Confirm the file at [path] is still on the rig and readable, and answer
  /// its size.
  ///
  /// [describe] without the hash, so the two cannot classify the same
  /// filesystem answer differently. A caller that only needs to know whether
  /// the rig still holds what it published — the delivery sweep's peer arm,
  /// which is asked that on every heartbeat pass for as long as the desktop
  /// leaves a file unpulled — would otherwise re-read every published master
  /// to answer a question `stat` answers. The checksum belongs where it is
  /// used: against the bytes a transport or a download is about to serve.
  static Future<int> confirmOnRig(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw DeliveryFailure(
        DeliveryFailureKind.sourceMissing,
        'The job produced $path but it is no longer on disk',
      );
    }
    try {
      return await file.length();
    } on PathAccessException catch (error) {
      throw DeliveryFailure(
        DeliveryFailureKind.permissionDenied,
        'Reading $path is not permitted',
        cause: error,
      );
    } on FileSystemException catch (error) {
      throw DeliveryFailure(
        DeliveryFailureKind.sourceMissing,
        'Reading $path failed: ${fileSystemReason(error)}',
        cause: error,
      );
    }
  }

  @override
  String toString() => 'DeliveryFile($fileName, $bytes bytes)';
}

/// A [DeliveryFile] whose class of artifact is known, so destinations can
/// select it.
class DeliveryArtifact extends DeliveryFile {
  /// Which class of artifact this is. A destination receives it only when its
  /// [ArtifactDestination.content] selection includes this.
  final ArtifactContent content;

  const DeliveryArtifact({
    required this.content,
    required super.sourcePath,
    required super.bytes,
    required super.checksum,
  });

  /// Stat and hash the file at [path] as an artifact of class [content].
  static Future<DeliveryArtifact> describeArtifact({
    required ArtifactContent content,
    required String path,
  }) async {
    final file = await DeliveryFile.describe(path);
    return DeliveryArtifact(
      content: content,
      sourcePath: file.sourcePath,
      bytes: file.bytes,
      checksum: file.checksum,
    );
  }

  @override
  String toString() =>
      'DeliveryArtifact(${content.wire}, $fileName, $bytes bytes)';
}

/// Everything one dawn job delivers, in a fixed order.
class DeliveryArtifactSet {
  /// The `darkroom_jobs.id` these artifacts belong to. Journal rows key on it,
  /// so the set cannot be delivered without one.
  final int jobId;

  /// The artifacts, ordered by artifact class and then by the order the
  /// caller listed them, so two runs of the same job deliver in the same
  /// order.
  final List<DeliveryArtifact> artifacts;

  const DeliveryArtifactSet({required this.jobId, required this.artifacts});

  /// The artifacts a destination has selected, in set order.
  List<DeliveryArtifact> selectedFor(ArtifactDestination destination) =>
      artifacts
          .where((a) => destination.content.contains(a.content))
          .toList(growable: false);

  /// Read [sources] off disk and hash each one.
  static Future<DeliveryArtifactSet> build({
    required int jobId,
    required Map<ArtifactContent, List<String>> sources,
  }) async {
    final artifacts = <DeliveryArtifact>[];
    for (final content in ArtifactContent.values) {
      final paths = sources[content];
      if (paths == null) continue;
      for (final path in paths) {
        artifacts.add(
          await DeliveryArtifact.describeArtifact(content: content, path: path),
        );
      }
    }
    return DeliveryArtifactSet(jobId: jobId, artifacts: artifacts);
  }

  @override
  String toString() =>
      'DeliveryArtifactSet(job=$jobId, ${artifacts.length} files)';
}

/// Lowercase hex SHA-256 of [file], read as a stream.
///
/// Streamed rather than `readAsBytes` because a linear master is gigabytes and
/// this runs on an appliance that is also holding a night of frames in RAM.
Future<String> sha256OfFile(File file) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  try {
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
  } on PathAccessException catch (error) {
    throw DeliveryFailure(
      DeliveryFailureKind.permissionDenied,
      'Reading ${file.path} is not permitted',
      cause: error,
    );
  } on FileSystemException catch (error) {
    throw DeliveryFailure(
      DeliveryFailureKind.sourceMissing,
      'Reading ${file.path} failed: ${fileSystemReason(error)}',
      cause: error,
    );
  } finally {
    input.close();
  }
  return sink.digest.toString();
}

/// Collects the one [Digest] a chunked SHA-256 conversion emits.
class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  /// The digest the conversion produced. Reading it before the conversion is
  /// closed is a programming error, so it throws rather than inventing a hash
  /// that would then be compared against real bytes.
  Digest get digest {
    final value = _digest;
    if (value == null) {
      throw StateError('SHA-256 digest read before the conversion closed');
    }
    return value;
  }

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}
