import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:skotiq_app/services/host_folders.dart';
import 'package:skotiq_core/backend.dart';

typedef FolderPick = Future<String?> Function({
  required HostFiles? host,
  required String? initialPath,
});

typedef FolderCheckAnswer = Future<FolderCheck> Function(
  String path,
  HostFiles? host,
);

/// [HostFolders] without a file picker, a disk or a file manager: picks
/// answer [onPick], checks [onCheck] (every folder takes files by default),
/// and reveals and creations are recorded.
class FakeHostFolders extends HostFolders {
  FakeHostFolders({this.onPick, this.onCheck});

  FolderPick? onPick;
  FolderCheckAnswer? onCheck;

  final List<({HostFiles? host, String? initialPath})> picks = [];
  final List<String> checked = [];
  final List<String> created = [];
  final List<String> revealed = [];

  @override
  Future<String?> pick(
    BuildContext context, {
    required HostFiles? host,
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  }) {
    picks.add((host: host, initialPath: initialPath));
    return onPick?.call(host: host, initialPath: initialPath) ??
        Future<String?>.value();
  }

  @override
  Future<FolderCheck> check(String path, {required HostFiles? host}) {
    checked.add(path);
    return onCheck?.call(path, host) ??
        Future<FolderCheck>.value(const FolderUsable());
  }

  @override
  Future<void> create(String path) async => created.add(path);

  @override
  Future<void> reveal(BuildContext context, String path) async =>
      revealed.add(path);
}

/// A check that answers as [problem] does: null for a folder that takes
/// files, otherwise the reason it does not.
FolderCheckAnswer folderCheckFrom(
  FutureOr<String?> Function(String path) problem,
) =>
    (path, host) async {
      final reason = await problem(path);
      return reason == null ? const FolderUsable() : FolderRefused(reason);
    };
