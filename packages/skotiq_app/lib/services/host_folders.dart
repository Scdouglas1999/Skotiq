import 'dart:io';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';

import '../utils/snackbar_helper.dart';
import '../widgets/remote_directory_picker_dialog.dart';

/// What a check of a folder found.
sealed class FolderCheck {
  const FolderCheck();
}

/// The folder is there and takes files.
final class FolderUsable extends FolderCheck {
  const FolderUsable();
}

/// No folder at that path yet.
final class FolderMissing extends FolderCheck {
  const FolderMissing();
}

/// The path cannot hold files; [reason] says why in words an operator can act
/// on.
class FolderRefused extends FolderCheck {
  const FolderRefused(this.reason);

  final String reason;
}

/// Not a full path, so it names no folder at all and cannot be stored even
/// for a drive that is not mounted yet.
final class FolderNotFullPath extends FolderRefused {
  const FolderNotFullPath(super.reason);
}

/// The check could not be made, for [reason] (the host did not answer).
final class FolderUnchecked extends FolderCheck {
  const FolderUnchecked(this.reason);

  final String reason;
}

/// A folder chosen in a picker and what its check found.
typedef PickedFolder = ({String path, FolderCheck verdict});

/// The folders the imaging host writes into (captures, flats), for every
/// screen that asks for one: on this computer when it is the host, on the
/// linked host otherwise ([hostFoldersProvider] picks the side). One rule for
/// both: a full path to a folder that exists and takes a file. Screens keep
/// only their titles and what they do with a missing folder.
abstract class HostFolders {
  const HostFolders();

  /// The folder picker of the side these folders are on.
  Future<String?> pick(
    BuildContext context, {
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  });

  /// Whether [path] can take files.
  Future<FolderCheck> check(String path);

  /// [check], after making [path] when it is missing and this side makes
  /// folders on request.
  Future<FolderCheck> prepare(String path);

  /// [pick], with the picked folder's [check].
  Future<PickedFolder?> pickChecked(
    BuildContext context, {
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  }) async {
    final picked = await pick(
      context,
      title: title,
      initialPath: initialPath,
      confirmLabel: confirmLabel,
    );
    if (picked == null) return null;
    return (path: picked, verdict: await check(picked));
  }

  /// [pickChecked], keeping only a folder that takes files: any other is
  /// refused with its reason shown and null returned.
  Future<String?> pickUsable(
    BuildContext context, {
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  }) async {
    final picked = await pickChecked(
      context,
      title: title,
      initialPath: initialPath,
      confirmLabel: confirmLabel,
    );
    if (picked == null) return null;
    final (:path, :verdict) = picked;
    if (verdict is FolderUsable) return path;
    if (context.mounted) {
      context.showErrorSnackBar(switch (verdict) {
        FolderRefused(:final reason) ||
        FolderUnchecked(:final reason) =>
          '$path cannot be used. $reason',
        _ => '$path is not there any more.',
      });
    }
    return null;
  }
}

/// Folders on this computer: the system picker, a write probe, and the file
/// manager. Also what [localFoldersProvider] hands to screens whose folder is
/// always this computer's (backups, the app's data and logs, exports).
class LocalFolders extends HostFolders {
  const LocalFolders();

  @override
  Future<String?> pick(
    BuildContext context, {
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  }) {
    final start = initialPath?.trim();
    return file_selector.getDirectoryPath(
      confirmButtonText: confirmLabel,
      initialDirectory: start == null || start.isEmpty ? null : start,
    );
  }

  @override
  Future<FolderCheck> check(String path) async {
    final folder = path.trim();
    if (folder.isEmpty) return const FolderRefused('Enter a folder.');
    if (!p.isAbsolute(folder)) {
      return FolderNotFullPath(
        'Enter a full path, such as '
        '${Platform.isWindows ? r'D:\Astro\Lights' : '/home/you/Astro'}.',
      );
    }
    final directory = Directory(folder);
    if (!await directory.exists()) {
      return await File(folder).exists()
          ? const FolderRefused('That is a file, not a folder.')
          : const FolderMissing();
    }
    final probe = File(p.join(folder, '.skotiq_write_probe'));
    try {
      await probe.writeAsString('probe');
      await probe.delete();
      return const FolderUsable();
    } on FileSystemException catch (error) {
      return FolderRefused(notWritableReason(error));
    }
  }

  @override
  Future<FolderCheck> prepare(String path) async {
    final verdict = await check(path);
    if (verdict is! FolderMissing) return verdict;
    try {
      await create(path);
    } on FileSystemException catch (error) {
      return FolderRefused(userFacingError(error));
    }
    return check(path);
  }

  /// Makes a missing folder.
  Future<void> create(String path) =>
      Directory(path.trim()).create(recursive: true);

  /// Opens [path] in the file manager, or copies it where there is none to
  /// open (a phone or tablet). A folder the app writes to may not exist until
  /// its first file, and a file manager cannot open it before then, so it is
  /// made first.
  Future<void> reveal(BuildContext context, String path) async {
    await create(path);
    if (Platform.isAndroid || Platform.isIOS) {
      await Clipboard.setData(ClipboardData(text: path));
      if (context.mounted) context.showSuccessSnackBar('Path copied: $path');
      return;
    }
    final opener = Platform.isWindows
        ? 'explorer'
        : Platform.isMacOS
            ? 'open'
            : 'xdg-open';
    await Process.start(opener, [path], runInShell: true);
  }
}

/// Folders on the linked imaging host: its folder browser, and the host's own
/// check of a path.
class LinkedHostFolders extends HostFolders {
  const LinkedHostFolders(this._files);

  final HostFiles _files;

  @override
  Future<String?> pick(
    BuildContext context, {
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  }) =>
      RemoteDirectoryPickerDialog.show(
        context,
        title: title,
        initialPath: initialPath,
      );

  /// The host's folder browser checks a folder before it closes.
  @override
  Future<PickedFolder?> pickChecked(
    BuildContext context, {
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  }) async {
    final picked = await pick(context, title: title, initialPath: initialPath);
    return picked == null
        ? null
        : (path: picked, verdict: const FolderUsable());
  }

  @override
  Future<FolderCheck> check(String path) async {
    final folder = path.trim();
    if (folder.isEmpty) return const FolderRefused('Enter a folder.');
    final Map<String, dynamic> result;
    try {
      result = await _files.validateRemoteDirectory(
        folder,
        mustExist: true,
        mustBeWritable: true,
      );
    } catch (error) {
      return FolderUnchecked(
        'Could not ask the imaging host about this folder: '
        '${userFacingError(error)}',
      );
    }
    if (result['valid'] == true) return const FolderUsable();
    if (result['exists'] == false && result['error'] == null) {
      return const FolderMissing();
    }
    final reason = result['error'];
    return FolderRefused(
      reason is String && reason.trim().isNotEmpty
          ? reason.trim()
          : result['exists'] == true
              ? 'The imaging host cannot write to this folder.'
              : 'The imaging host refused this folder.',
    );
  }

  /// The host makes no folder on request from a client, so this is [check].
  @override
  Future<FolderCheck> prepare(String path) => check(path);
}

/// The one line a failed write probe shows. [FileSystemException.message] is
/// the generic dart:io phrase ("Cannot open file"); the cause an operator can
/// act on ("Permission denied", "Read-only file system") is only in
/// [OSError.message].
String notWritableReason(FileSystemException error) {
  final reason = error.osError?.message.trim() ?? '';
  return reason.isEmpty
      ? 'Not writable: ${error.message}'
      : 'Not writable: $reason';
}

/// Folders on this computer, whichever machine is the imaging host.
final localFoldersProvider =
    Provider<LocalFolders>((ref) => const LocalFolders());

/// The folders the imaging host writes into. A new value when the host
/// changes, so work started for one host can tell it is stale.
final hostFoldersProvider = hostRoleProvider<HostFolders>(
  here: (ref) => ref.watch(localFoldersProvider),
  linked: (ref, host) => LinkedHostFolders(host.files),
);
