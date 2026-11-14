import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/daos/settings_dao.dart';
import '../settings/app_settings_state.g.dart' show AppSettingDefs;
import '../utils/skotiq_data_directory.dart';

/// Where the files a night produces after capture go: the masters built from
/// its frames and the Darkroom's drafts, pass logs and exports.
///
/// Everything lands under one root, the capture folder (Settings, "Image
/// output"), or `Skotiq` in the documents folder when none is set:
///
///     <root>/Masters/<target>/   masters of one target, from Session Review
///                                and from Darkroom builds
///     <root>/darkroom/           drafts, night reports and pass logs
///
/// Files already written stay where they are; the library rows name their
/// paths.
class OutputLocations {
  OutputLocations({required String captureFolder, required this.documents})
    : captureFolder = captureFolder.trim();

  /// The locations for this computer's capture folder setting.
  static Future<OutputLocations> read(
    SettingsDao settings, {
    Future<Directory> Function() documents = resolveSkotiqDocumentsDirectory,
  }) async => OutputLocations(
    captureFolder: await settings.read(AppSettingDefs.imageOutputPath),
    documents: await documents(),
  );

  /// The capture folder, or empty when none is set.
  final String captureFolder;

  /// The platform documents folder (see [resolveSkotiqDocumentsDirectory]).
  final Directory documents;

  String get _skotiqDocuments => p.join(documents.path, 'Skotiq');

  String get root => captureFolder.isEmpty ? _skotiqDocuments : captureFolder;

  Directory get masters => Directory(p.join(root, 'Masters'));

  Directory get darkroom => Directory(p.join(root, 'darkroom'));

  /// The folder [target]'s masters go into under [parent]: one folder per
  /// target, so each night folds into the same build.
  static Directory targetFolder(Directory parent, String target) => Directory(
    p.join(parent.path, target.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')),
  );

  /// The folder [target]'s masters go into.
  ///
  /// A target whose masters already live under `Documents/Skotiq/Masters`
  /// while a capture folder is set keeps them there: a Darkroom build's plan
  /// and per-filter receipts in that folder let the next night reuse the
  /// filters it finished and replace the masters it registered.
  Future<Directory> mastersOf(String target) async {
    final folder = targetFolder(masters, target);
    final documentsFolder = targetFolder(
      Directory(p.join(_skotiqDocuments, 'Masters')),
      target,
    );
    if (folder.path != documentsFolder.path &&
        !await folder.exists() &&
        await documentsFolder.exists()) {
      return documentsFolder;
    }
    return folder;
  }
}
