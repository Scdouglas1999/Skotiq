import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/services/host_folders.dart';
import 'package:skotiq_core/providers.dart';

typedef FolderPick = Future<String?> Function({required String? initialPath});

typedef FolderCheckAnswer = Future<FolderCheck> Function(String path);

/// [LocalFolders] without a file picker, a disk or a file manager: picks
/// answer [onPick], checks [onCheck] (every folder takes files by default),
/// and making or opening a folder does nothing.
class FakeHostFolders extends LocalFolders {
  FakeHostFolders({this.onPick, this.onCheck});

  FolderPick? onPick;
  FolderCheckAnswer? onCheck;

  @override
  Future<String?> pick(
    BuildContext context, {
    required String title,
    String? initialPath,
    String confirmLabel = 'Select',
  }) =>
      onPick?.call(initialPath: initialPath) ?? Future<String?>.value();

  @override
  Future<FolderCheck> check(String path) =>
      onCheck?.call(path) ?? Future<FolderCheck>.value(const FolderUsable());

  @override
  Future<void> create(String path) async {}

  @override
  Future<void> reveal(BuildContext context, String path) async {}
}

/// [hostFoldersProvider] answered by a new fake from [make] for every host,
/// as the real role hands out new folders when the imaging host changes.
Override fakeHostFoldersPerHost(FakeHostFolders Function() make) =>
    hostFoldersProvider.overrideWith((ref) {
      ref.watch(remoteHostProvider);
      return make();
    });

/// A check that answers as [problem] does: null for a folder that takes
/// files, otherwise the reason it does not.
FolderCheckAnswer folderCheckFrom(
  FutureOr<String?> Function(String path) problem,
) =>
    (path) async {
      final reason = await problem(path);
      return reason == null ? const FolderUsable() : FolderRefused(reason);
    };
