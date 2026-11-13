import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'sequence_stats_provider.dart'
    show sequenceRunsDaoProvider, sequenceVersionsDaoProvider;
import '../backend/remote_host.dart';
import '../services/sequence_repository.dart';
import 'sequence_file_service_provider.dart';

final sequenceRepositoryProvider = Provider<SequenceRepository>((ref) {
  final backend = ref.watch(backendProvider);
  final host = backend.remoteHost?.sequences;
  if (host != null) {
    return SequenceRepository.remote(
      host,
      ref.watch(sequenceFileServiceProvider),
    );
  }
  return SequenceRepository(
    ref.watch(sequencesDaoProvider),
    runsDao: ref.watch(sequenceRunsDaoProvider),
    versionsDao: ref.watch(sequenceVersionsDaoProvider),
    fileService: ref.watch(sequenceFileServiceProvider),
  );
});
