part of '../polar_alignment_provider.dart';

/// The polar alignment history of whichever machine is the imaging host.
final polarAlignmentLogProvider = hostRoleProvider<PolarAlignmentLog>(
  here: (ref) => ref.watch(databaseProvider).polarAlignmentHistoryDao,
  linked: (ref, host) => host.polarAlignmentLog,
);

final polarAlignmentHistoryProvider =
    FutureProvider.family<List<PolarAlignmentHistoryEntry>, int?>(
      (ref, profileId) =>
          ref.watch(polarAlignmentLogProvider).getHistoryForProfile(profileId),
    );

final lastPolarAlignmentProvider =
    FutureProvider.family<PolarAlignmentHistoryEntry?, int?>(
      (ref, profileId) =>
          ref.watch(polarAlignmentLogProvider).getLastAlignment(profileId),
    );

/// The history as it changes: a new alignment shows without a reload.
final polarAlignmentHistoryStreamProvider =
    StreamProvider.family<List<PolarAlignmentHistoryEntry>, int?>(
      (ref, profileId) =>
          ref.watch(polarAlignmentLogProvider).watchHistory(profileId),
    );
