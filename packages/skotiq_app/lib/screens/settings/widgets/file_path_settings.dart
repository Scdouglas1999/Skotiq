import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as p;

import '../../../services/host_folders.dart';
import '../../../utils/confirm_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../tours/tour_target.dart';
import 'settings_widgets.dart';

typedef FilePathSettingsWriter = Future<void> Function(
  String settingKey,
  String path,
);

/// Where [BackupService] actually writes, asked of the service itself so the
/// row cannot drift from the directory the backups land in.
///
/// Automatic backups default to ON with a 24 h interval, and "Maximum backups"
/// DELETES the oldest bundles from this folder. Without this row the Files &
/// Storage page names neither: it lists Image output and Sequences, says
/// application data is "managed automatically", and leaves a retention policy
/// pruning files in an undisclosed directory.
final backupDirectoryPathProvider = FutureProvider<String>((ref) async {
  final directory = await ref.watch(backupServiceProvider).getBackupDirectory();
  return directory.path;
});

/// Where the database, logs and crash reports actually are.
///
/// Attaching a log to a bug report, backing the database up by hand, and
/// checking which data directory a headless launch picked all start with
/// knowing the path, so the page states it rather than saying it is "managed
/// automatically".
final applicationDataPathProvider = FutureProvider<String>((ref) async {
  final databaseFile = await resolveDefaultDatabaseFile();
  return databaseFile.parent.path;
});

/// Where the rolling log files actually are.
///
/// NOT the database folder. `resolveDefaultDatabaseFile` resolves under the
/// documents directory (or [skotiqDatabaseDirEnv]) while
/// [resolveSkotiqDataDirectory] resolves under the platform
/// application-support directory (or [skotiqDataDirEnv]) and
/// `LoggingService` writes `<that>/logs`. Telling the operator to attach "the
/// database folder, which has the logs in it" to a bug report would hand us a
/// folder with no logs in it — the same untruth as the row that refused to name
/// anything, just harder to catch.
final applicationLogPathProvider = FutureProvider<String>((ref) async {
  final dataRoot = await resolveSkotiqDataDirectory();
  return p.join(dataRoot.path, 'logs');
});

/// The folder the operator explicitly chose, or null while backups still follow
/// the database. Only a chosen folder can be handed back, so this is what
/// decides whether the row offers "Use default".
final backupDirectoryOverrideProvider = FutureProvider<String?>((ref) {
  return ref.watch(backupServiceProvider).getConfiguredBackupDirectory();
});

/// Moves the backup folder. Null restores the default beside the database.
typedef BackupDirectoryWriter = Future<void> Function(String? path);

final backupDirectoryWriterProvider = Provider<BackupDirectoryWriter>((ref) {
  return (directoryPath) =>
      ref.read(backupServiceProvider).setBackupDirectory(directoryPath);
});

final filePathSettingsWriterProvider = Provider<FilePathSettingsWriter>((ref) {
  return (settingKey, path) async {
    final notifier = ref.read(appSettingsProvider.notifier);
    switch (settingKey) {
      case 'image':
        await notifier.setImageOutputPath(path);
      case 'sequences':
        await notifier.setSequencesPath(path);
      default:
        throw ArgumentError.value(settingKey, 'settingKey');
    }
  };
});

class FilePathSettings extends ConsumerWidget {
  const FilePathSettings({
    super.key,
  });

  Future<void> _selectPath(
    BuildContext context,
    WidgetRef ref,
    String settingKey,
    String currentPath,
  ) async {
    final host = ref.backendScope();
    final isRemoteMode = ref.read(isRemoteModeProvider);
    // Only `image_output_path` is carried by the remote wire model; the three
    // infra paths (sequences/database/logs) are excluded from partial
    // persistence and setting them throws UnsupportedError. Block the picker
    // up-front in remote mode so the user gets a clear message instead of an
    // unhandled exception.
    if (isRemoteMode && settingKey != 'image') {
      context.showWarningSnackBar(
          'This path can only be changed on the host machine.');
      return;
    }
    try {
      final result = await ref.read(hostFoldersProvider).pickUsable(
        context,
        title: isRemoteMode ? 'Select host folder' : 'Select folder',
        initialPath: currentPath,
      );

      if (!context.mounted || result == null) return;
      if (host.isStale) {
        context.showWarningSnackBar(
          'The imaging host changed while choosing that folder. Choose it '
          'again for the current host.',
        );
        return;
      }

      await ref.read(filePathSettingsWriterProvider)(settingKey, result);
      if (!context.mounted || host.isStale) {
        return;
      }
      if (settingKey == 'sequences') {
        // The sequence file service watches settings and updates its initial
        // directory immediately — no restart required.
        context.showSuccessSnackBar(
          'Sequences directory updated. New exports/imports will start here.',
        );
      }
    } catch (e) {
      if (context.mounted && host.isCurrent) {
        context.showErrorSnackBar(
            'Could not update the storage path: ${userFacingError(e)}');
      }
    }
  }

  /// Accept a hand-typed storage path.
  ///
  /// The box looked like a text input and silently ignored every keystroke, so
  /// the ONLY way to set these was the folder picker — which cannot reach a
  /// share that is not mounted yet, and on a phone/tablet cannot reach the
  /// imaging host's disk at all. Typed paths are checked rather than trusted:
  /// a relative path is refused outright, and a folder this machine cannot
  /// create is confirmed before it is stored, so a 3am typo does not become a
  /// night of frames written nowhere.
  Future<void> _enterPath(
    BuildContext context,
    WidgetRef ref,
    String settingKey,
    String typed,
  ) async {
    final host = ref.backendScope();
    final isRemoteMode = ref.read(isRemoteModeProvider);
    final path = typed.trim();

    if (path.isEmpty) {
      context.showWarningSnackBar(
        'Enter a full folder path, or use the folder button to pick one.',
      );
      return;
    }
    if (isRemoteMode && settingKey != 'image') {
      context.showWarningSnackBar(
        'This path can only be changed on the host machine.',
      );
      return;
    }
    final verdict = await ref.read(hostFoldersProvider).prepare(path);
    if (!context.mounted || host.isStale) return;
    switch (verdict) {
      case FolderUsable():
        break;
      case FolderNotFullPath(:final reason):
        context.showWarningSnackBar(reason);
        return;
      case FolderMissing() ||
            FolderRefused() ||
            FolderUnchecked():
        final reason = switch (verdict) {
          FolderRefused(:final reason) || FolderUnchecked(:final reason) =>
            reason,
          _ => 'There is no folder there.',
        };
        final where = isRemoteMode ? 'the imaging host' : 'this machine';
        final useAnyway = await ConfirmDialog.show(
          context: context,
          title: 'Use a folder $where cannot open?',
          message: 'Skotiq could not use "$path" on $where:\n$reason\n\n'
              'Store it anyway if the drive or share is simply not mounted '
              'yet. Captures will fail until it is.',
          confirmLabel: 'Store anyway',
          isDestructive: true,
        );
        if (!useAnyway || !context.mounted || host.isStale) return;
    }

    await ref.read(filePathSettingsWriterProvider)(settingKey, path);
    if (!context.mounted || host.isStale) {
      return;
    }
    context.showSuccessSnackBar(
      isRemoteMode
          ? 'Image output set to $path on the imaging host.'
          : switch (settingKey) {
              'sequences' => 'Sequences directory set to $path. New '
                  'exports/imports will start here.',
              _ => 'Image output set to $path.',
            },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => const SettingsLoadingState(),
      error: (error, stack) => SettingsErrorState(
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);
        final isRemoteMode = ref.watch(isRemoteModeProvider);
        final hostHint = isRemoteMode ? ' (on imaging host)' : '';
        return SettingsPage(
          key: TourTarget.settingsFilePaths.key,
          title: 'File paths',
          description: isRemoteMode
              ? 'Storage locations on the connected imaging host'
              : 'Configure storage locations',
          children: [
            SettingsSection(
              title: 'Storage',
              children: [
                SettingRow(
                  // A path is long and the input is a fixed-width control, so
                  // side-by-side it collided with the (wrapping) title: on a
                  // 411dp phone the Storage card overflowed RIGHT by 66px, a
                  // visible hazard stripe over the card edge. Stacked, the
                  // input gets the row's full width and the path ellipsizes
                  // inside it instead of pushing past the card.
                  stackWhenNarrow: true,
                  icon: LucideIcons.image,
                  title: 'Image output$hostHint',
                  subtitle: settings.imageOutputPath.isEmpty
                      ? 'Not configured'
                      : settings.imageOutputPath,
                  trailing: SettingsPathInput(
                    fillWhenNarrow: true,
                    path: settings.imageOutputPath,
                    authorityKey: authority,
                    onBrowse: () => _selectPath(
                        context, ref, 'image', settings.imageOutputPath),
                    onPathEntered: (value) =>
                        _enterPath(context, ref, 'image', value),
                  ),
                ),
                SettingRow(
                  stackWhenNarrow: true,
                  icon: LucideIcons.listOrdered,
                  title: 'Sequences$hostHint',
                  subtitle: settings.sequencesPath.isEmpty
                      ? 'Not configured'
                      : settings.sequencesPath,
                  trailing: SettingsPathInput(
                    fillWhenNarrow: true,
                    path: settings.sequencesPath,
                    authorityKey: authority,
                    onBrowse: () => _selectPath(
                      context,
                      ref,
                      'sequences',
                      settings.sequencesPath,
                    ),
                    onPathEntered: (value) =>
                        _enterPath(context, ref, 'sequences', value),
                  ),
                  isLast: true,
                ),
              ],
            ),
            if (!isRemoteMode)
              const SettingsSection(
                title: 'Application data',
                children: [
                  _AppDataFolderRow(),
                  _BackupFolderRow(),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Names the folder the database, logs and crash reports live in.
class _AppDataFolderRow extends ConsumerWidget {
  const _AppDataFolderRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pathAsync = ref.watch(applicationDataPathProvider);
    final resolved = pathAsync.valueOrNull;
    final logPathAsync = ref.watch(applicationLogPathProvider);
    final resolvedLogs = logPathAsync.valueOrNull;
    // Only mentioned when it is actually in force: on a normal desktop install
    // the variable is noise, but on a headless/systemd host it is the reason
    // the folder is not where the operator expects.
    final pinned =
        Platform.environment[skotiqDatabaseDirEnv]?.trim().isNotEmpty ?? false;
    const contents =
        'skotiq.db and any recovered or quarantined database files.';
    // The logs are NOT under the database folder — different resolver,
    // different root — so they get their own line and their own button. A
    // bug-report instruction pointing at one folder containing both would be
    // false.
    final logsLine = switch (logPathAsync) {
      AsyncData(:final value) => 'Logs: $value',
      AsyncError(:final error) => 'Could not resolve the logs folder: $error',
      _ => 'Resolving the logs folder…',
    };
    const attach = 'Attach both folders to a bug report.';
    final subtitle = switch (pathAsync) {
      AsyncData(:final value) => pinned
          ? '$value\n$contents\nPinned here by $skotiqDatabaseDirEnv.\n'
              '$logsLine\n$attach'
          : '$value\n$contents\n$logsLine\n$attach',
      AsyncError(:final error) =>
        'Could not resolve the application data folder: $error\n$logsLine',
      _ => 'Resolving the application data folder…\n$logsLine',
    };

    final openLabel =
        Platform.isAndroid || Platform.isIOS ? 'Copy path' : 'Open folder';
    final openLogsLabel =
        Platform.isAndroid || Platform.isIOS ? 'Copy logs path' : 'Open logs';

    return SettingRow(
      icon: LucideIcons.database,
      title: 'Database and logs',
      subtitle: subtitle,
      stackWhenNarrow: true,
      trailing: Wrap(
        spacing: SkotiqTokens.spaceSm,
        runSpacing: SkotiqTokens.spaceXs,
        children: [
          if (resolved != null)
            SkotiqButton(
              label: openLabel,
              icon: LucideIcons.folderOpen,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () async {
                try {
                  await ref.read(localFoldersProvider).reveal(
                    context,
                    resolved,
                  );
                } catch (e) {
                  if (context.mounted) {
                    context.showErrorSnackBar(
                      'Could not open the application data folder: ${userFacingError(e)}',
                    );
                  }
                }
              },
            ),
          if (resolvedLogs != null)
            SkotiqButton(
              label: openLogsLabel,
              icon: LucideIcons.scrollText,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () async {
                try {
                  await ref.read(localFoldersProvider).reveal(
                    context,
                    resolvedLogs,
                  );
                } catch (e) {
                  if (context.mounted) {
                    context.showErrorSnackBar(
                      'Could not open the logs folder: ${userFacingError(e)}',
                    );
                  }
                }
              },
            ),
        ],
      ),
    );
  }
}

/// Names the folder automatic backups are written to — and pruned from.
class _BackupFolderRow extends ConsumerWidget {
  const _BackupFolderRow();

  /// Apply [directoryPath] (null = back to the default) and refresh the two
  /// providers that describe the folder, so the row re-reads the service rather
  /// than echoing what was just typed at it.
  Future<void> _move(
    BuildContext context,
    WidgetRef ref,
    String? directoryPath,
  ) async {
    try {
      await ref.read(backupDirectoryWriterProvider)(directoryPath);
      ref.invalidate(backupDirectoryPathProvider);
      ref.invalidate(backupDirectoryOverrideProvider);
      if (!context.mounted) return;
      context.showSuccessSnackBar(
        directoryPath == null
            ? 'Backups will be written beside the database again.'
            : 'Backups will be written to $directoryPath.',
      );
    } catch (e) {
      // A folder that cannot be created is the whole reason this fails loudly:
      // an unmounted or read-only volume must not be accepted here and then
      // discovered at 3am when the scheduled backup fires.
      if (context.mounted) {
        context.showErrorSnackBar(
            'Could not use that backup folder: ${userFacingError(e)}');
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pathAsync = ref.watch(backupDirectoryPathProvider);
    final resolved = pathAsync.valueOrNull;
    final override = ref.watch(backupDirectoryOverrideProvider).valueOrNull;
    // The retention sentence is unconditional: "Maximum backups" deletes from
    // this folder whether or not the path has resolved yet. Which folder that
    // is changes once the operator moves it — claiming "beside the database"
    // about a folder they pointed at another drive would be a fresh untruth.
    final retention = override == null
        ? 'Automatic backups are written here, beside the database; “Maximum '
            'backups” deletes the oldest bundles from this folder.'
        : 'Automatic backups are written to the folder you chose; “Maximum '
            'backups” deletes the oldest bundles from this folder.';
    final subtitle = switch (pathAsync) {
      AsyncData(:final value) => '$value\n$retention',
      AsyncError(:final error) =>
        'Could not resolve the backup folder: $error\n$retention',
      _ => 'Resolving the backup folder…\n$retention',
    };

    return SettingRow(
      icon: LucideIcons.archive,
      title: 'Backups',
      subtitle: subtitle,
      stackWhenNarrow: true,
      isLast: true,
      trailing: Wrap(
        spacing: SkotiqTokens.spaceSm,
        runSpacing: SkotiqTokens.spaceXs,
        children: [
          // Browsing does not depend on the current path resolving: an install
          // whose default folder cannot be resolved is exactly the one that
          // most needs to be pointed somewhere else.
          SkotiqButton(
            label: 'Change…',
            icon: LucideIcons.folderOpen,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () async {
              final picked = await ref.read(localFoldersProvider).pickUsable(
                context,
                title: 'Select backup folder',
                initialPath: resolved,
              );
              if (picked == null || !context.mounted) return;
              await _move(context, ref, picked);
            },
          ),
          if (override != null)
            SkotiqButton(
              label: 'Use default',
              icon: LucideIcons.rotateCcw,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => _move(context, ref, null),
            ),
          if (resolved != null)
            SkotiqButton(
              label: Platform.isAndroid || Platform.isIOS
                  ? 'Copy path'
                  : 'Open folder',
              icon: LucideIcons.folderOpen,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () async {
                try {
                  await ref.read(localFoldersProvider).reveal(
                    context,
                    resolved,
                  );
                } catch (e) {
                  if (context.mounted) {
                    context.showErrorSnackBar(
                      'Could not open the backup folder: ${userFacingError(e)}',
                    );
                  }
                }
              },
            ),
        ],
      ),
    );
  }
}
