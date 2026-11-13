import 'dart:io';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';

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
final class FolderRefused extends FolderCheck {
  const FolderRefused(this.reason);

  final String reason;
}

/// The check could not be made, for [reason] (the host did not answer).
final class FolderUnchecked extends FolderCheck {
  const FolderUnchecked(this.reason);

  final String reason;
}

/// Choosing a folder, checking that it takes files, and showing it, for every
/// screen that asks for one. A folder is on this computer, or on the linked
/// host when a [HostFiles] is given (`backend.remoteHost?.files`). One rule
/// for both: a full path to a folder that exists and takes a file. Screens
/// keep only their titles and what they do with a missing folder.
///
/// Tests replace it through [hostFoldersProvider].
class HostFolders {
  const HostFolders();

  /// The system folder picker, or the host's folder browser.
  Future<String?> pick(
    BuildContext context, {
    required HostFiles? host,
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  }) {
    if (host != null) {
      return RemoteDirectoryPickerDialog.show(
        context,
        title: title,
        initialPath: initialPath,
      );
    }
    final start = initialPath?.trim();
    return file_selector.getDirectoryPath(
      confirmButtonText: confirmLabel,
      initialDirectory: start == null || start.isEmpty ? null : start,
    );
  }

  /// [pick], then the folder's [check]: a folder that cannot take files is
  /// refused with its reason shown and null returned. The host's folder
  /// browser makes the same check before it closes.
  Future<String?> pickUsable(
    BuildContext context, {
    required HostFiles? host,
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  }) async {
    final picked = await pick(
      context,
      host: host,
      title: title,
      initialPath: initialPath,
      confirmLabel: confirmLabel,
    );
    if (picked == null || host != null) return picked;
    final verdict = await check(picked, host: null);
    if (verdict is FolderUsable) return picked;
    if (context.mounted) {
      context.showErrorSnackBar(switch (verdict) {
        FolderRefused(:final reason) || FolderUnchecked(:final reason) =>
          '$picked cannot be used. $reason',
        _ => '$picked is not there any more.',
      });
    }
    return null;
  }

  /// Whether [path] can take files: on this computer, or on the linked host.
  Future<FolderCheck> check(String path, {required HostFiles? host}) async {
    final folder = path.trim();
    if (folder.isEmpty) return const FolderRefused('Enter a folder.');
    if (host != null) return _checkOnHost(host, folder);
    if (!p.isAbsolute(folder)) {
      return FolderRefused(
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

  Future<FolderCheck> _checkOnHost(HostFiles host, String folder) async {
    final Map<String, dynamic> result;
    try {
      result = await host.validateRemoteDirectory(
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

  /// Makes a missing folder on this computer.
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

final hostFoldersProvider = Provider<HostFolders>((ref) => const HostFolders());
