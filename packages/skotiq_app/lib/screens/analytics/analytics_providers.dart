import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

/// The frames of one session, as the imaging host records them.
final dbSessionImagesProvider =
    StreamProvider.family<List<DbCapturedImage>, int>(
  (ref, sessionId) =>
      ref.watch(capturedImageRowsProvider).watchSession(sessionId),
);

/// The frames taken outside any sequence: they belong to no session.
final standaloneImagesProvider = StreamProvider<List<DbCapturedImage>>(
  (ref) => ref.watch(capturedImageRowsProvider).watchStandalone(),
);
