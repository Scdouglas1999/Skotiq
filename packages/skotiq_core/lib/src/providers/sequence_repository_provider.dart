import 'database_provider.dart';
import 'host_role.dart';
import 'sequence_stats_provider.dart'
    show sequenceRunsDaoProvider, sequenceVersionsDaoProvider;
import '../services/local_sequence_repository.dart';
import '../services/remote_sequence_repository.dart';
import '../services/sequence_repository.dart';
import 'sequence_file_service_provider.dart';

/// The saved sequences of whichever machine is the imaging host.
final sequenceRepositoryProvider = hostRoleProvider<SequenceRepository>(
  here: (ref) => LocalSequenceRepository(
    ref.watch(sequencesDaoProvider),
    runsDao: ref.watch(sequenceRunsDaoProvider),
    versionsDao: ref.watch(sequenceVersionsDaoProvider),
    fileService: ref.watch(sequenceFileServiceProvider),
  ),
  linked: (ref, host) => RemoteSequenceRepository(
    host.sequences,
    ref.watch(sequenceFileServiceProvider),
  ),
);
