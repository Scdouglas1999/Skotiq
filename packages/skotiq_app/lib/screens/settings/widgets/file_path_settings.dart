import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../../../utils/confirm_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/remote_directory_picker_dialog.dart';
import '../../../widgets/tutorial_keys/settings_keys.dart';
import 'settings_widgets.dart';

typedef FilePathSettingsPicker = Future<String?> Function(
  BuildContext context, {
  required bool isRemote,
  required String currentPath,
});

typedef FilePathSettingsWriter = Future<void> Function(
  String settingKey,
  String path,
);

Future<String?> _pickFilePathSetting(
  BuildContext context, {
  required bool isRemote,
  required String currentPath,
}) {
  if (isRemote) {
    return RemoteDirectoryPickerDialog.show(
      context,
      title: 'Select host folder',
      initialPath: currentPath,
    );
  }
  return getDirectoryPath(confirmButtonText: 'Select');
}

final filePathSettingsPickerProvider =
    Provider<FilePathSettingsPicker>((ref) => _pickFilePathSetting);

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

/// Make a folder reachable: open it in the desktop file manager, or copy the
/// path where there is no file manager to open it in.
typedef BackupFolderRevealer = Future<void> Function(
  BuildContext context,
  String path,
);

Future<void> _revealFolder(BuildContext context, String path) async {
  // File managers cannot reveal a directory until the first backup creates it.
  await Directory(path).create(recursive: true);
  if (Platform.isAndroid || Platform.isIOS) {
    await Clipboard.setData(ClipboardData(text: path));
    if (context.mounted) {
      context.showSuccessSnackBar('Path copied: $path');
    }
    return;
  }
  if (Platform.isWindows) {
    await Process.start('explorer', [path], runInShell: true);
  } else if (Platform.isMacOS) {
    await Process.start('open', [path], runInShell: true);
  } else {
    await Process.start('xdg-open', [path], runInShell: true);
  }
}

final backupFolderRevealerProvider =
    Provider<BackupFolderRevealer>((ref) => _revealFolder);

/// Same action for the application data folder. Kept as its own provider so a
/// test can drive one row without stubbing the other.
final appDataFolderRevealerProvider =
    Provider<BackupFolderRevealer>((ref) => _revealFolder);

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

/// Answers whether this machine can actually store frames at [path]: null when
/// the folder is there (or was created), otherwise the reason it is not.
///
/// Injected so the typed-path flow is drivable without touching the disk.
typedef StorageDirectoryProbe = Future<String?> Function(String path);

Future<String?> _probeStorageDirectory(String path) async {
  try {
    await Directory(path).create(recursive: true);
    return null;
  } catch (error) {
    return '$error';
  }
}

final storageDirectoryProbeProvider =
    Provider<StorageDirectoryProbe>((ref) => _probeStorageDirectory);

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
  final bool isMobile;

  /// When true, render without an own scroll view / header (embedded in a
  /// merged section's single outer scroll).
  final bool embedded;

  const FilePathSettings({
    super.key,
    this.isMobile = false,
    this.embedded = false,
  });

  Future<void> _selectPath(
    BuildContext context,
    WidgetRef ref,
    String settingKey,
    String currentPath,
  ) async {
    final authority = ref.read(backendProvider);
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
      final result = await ref.read(filePathSettingsPickerProvider)(
        context,
        isRemote: isRemoteMode,
        currentPath: currentPath,
      );

      if (!context.mounted || result == null) return;
      if (!identical(ref.read(backendProvider), authority)) {
        context.showWarningSnackBar(
          'The imaging host changed while choosing that folder. Choose it '
          'again for the current host.',
        );
        return;
      }

      await ref.read(filePathSettingsWriterProvider)(settingKey, result);
      if (!context.mounted ||
          !identical(ref.read(backendProvider), authority)) {
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
      if (context.mounted && identical(ref.read(backendProvider), authority)) {
        context.showErrorSnackBar('Could not update the storage path: $e');
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
    final authority = ref.read(backendProvider);
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
    if (!p.isAbsolute(path)) {
      context.showWarningSnackBar(
        'Enter a full path, such as ${Platform.isWindows ? r'D:\Astro\Lights' : '/home/you/Astro'}.',
      );
      return;
    }

    if (!isRemoteMode) {
      final problem = await ref.read(storageDirectoryProbeProvider)(path);
      if (!context.mounted ||
          !identical(ref.read(backendProvider), authority)) {
        return;
      }
      if (problem != null) {
        final useAnyway = await ConfirmDialog.show(
          context: context,
          title: 'Use a folder this machine cannot open?',
          message: 'Skotiq could not create or reach "$path":\n$problem\n\n'
              'Store it anyway if the drive or share is simply not mounted '
              'yet. Captures will fail until it is.',
          confirmLabel: 'Store anyway',
          isDestructive: true,
        );
        if (!useAnyway ||
            !context.mounted ||
            !identical(ref.read(backendProvider), authority)) {
          return;
        }
      }
    }

    await ref.read(filePathSettingsWriterProvider)(settingKey, path);
    if (!context.mounted || !identical(ref.read(backendProvider), authority)) {
      return;
    }
    context.showSuccessSnackBar(
      isRemoteMode
          ? 'Image output set to $path on the imaging host — Skotiq '
              'cannot check that folder from here.'
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
      loading: () =>
          SettingsLoadingState(isMobile: isMobile, scrollable: !embedded),
      error: (error, stack) => SettingsErrorState(
        isMobile: isMobile,
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);
        final isRemoteMode = ref.watch(isRemoteModeProvider);
        final hostHint = isRemoteMode ? ' (on imaging host)' : '';
        return SettingsPage(
          key: SettingsTutorialKeys.filePaths,
          title: 'File paths',
          description: isRemoteMode
              ? 'Storage locations on the connected imaging host'
              : 'Configure storage locations',
          isMobile: isMobile,
          hideHeader: embedded,
          scrollable: !embedded,
          children: [
            SettingsSection(
              title: 'Storage',
              children: [
                SettingRow(
                  isMobile: isMobile,
                  // A path is long and the input is a fixed-width control, so
                  // side-by-side it collided with the (wrapping) title: on a
                  // 411dp phone the Storage card overflowed RIGHT by 66px, a
                  // visible hazard stripe over the card edge. Stacked, the
                  // input gets the row's full width and the path ellipsizes
                  // inside it instead of pushing past the card.
                  stackOnMobile: true,
                  icon: LucideIcons.image,
                  title: 'Image output$hostHint',
                  subtitle: settings.imageOutputPath.isEmpty
                      ? 'Not configured'
                      : settings.imageOutputPath,
                  trailing: SettingsPathInput(
                    isMobile: isMobile,
                    flexible: isMobile,
                    path: settings.imageOutputPath,
                    authorityKey: authority,
                    onBrowse: () => _selectPath(
                        context, ref, 'image', settings.imageOutputPath),
                    onPathEntered: (value) =>
                        _enterPath(context, ref, 'image', value),
                  ),
                ),
                SettingRow(
                  isMobile: isMobile,
                  stackOnMobile: true,
                  icon: LucideIcons.listOrdered,
                  title: 'Sequences$hostHint',
                  subtitle: settings.sequencesPath.isEmpty
                      ? 'Not configured'
                      : settings.sequencesPath,
                  trailing: SettingsPathInput(
                    isMobile: isMobile,
                    flexible: isMobile,
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
              SettingsSection(
                title: 'Application data',
                children: [
                  _AppDataFolderRow(isMobile: isMobile),
                  _BackupFolderRow(isMobile: isMobile),
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
  const _AppDataFolderRow({required this.isMobile});

  final bool isMobile;

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
        Platform.environment[skotiqDatabaseDirEnv]?.trim().isNotEmpty ??
            false;
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
      isMobile: isMobile,
      stackOnMobile: isMobile,
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
                  await ref.read(appDataFolderRevealerProvider)(
                    context,
                    resolved,
                  );
                } catch (e) {
                  if (context.mounted) {
                    context.showErrorSnackBar(
                      'Could not open the application data folder: $e',
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
                  await ref.read(appDataFolderRevealerProvider)(
                    context,
                    resolvedLogs,
                  );
                } catch (e) {
                  if (context.mounted) {
                    context.showErrorSnackBar(
                      'Could not open the logs folder: $e',
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
  const _BackupFolderRow({required this.isMobile});

  final bool isMobile;

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
        context.showErrorSnackBar('Could not use that backup folder: $e');
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
      isMobile: isMobile,
      stackOnMobile: isMobile,
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
              final picked = await ref.read(filePathSettingsPickerProvider)(
                context,
                isRemote: false,
                currentPath: switch (resolved) {
                  null => '',
                  final path => path,
                },
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
                  await ref.read(backupFolderRevealerProvider)(
                    context,
                    resolved,
                  );
                } catch (e) {
                  if (context.mounted) {
                    context.showErrorSnackBar(
                      'Could not open the backup folder: $e',
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
