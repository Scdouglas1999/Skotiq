// The rig's capture drive. The scene is a Windows rig that saves to
// `D:\Astro\Skotiq`; on the machine rendering the screenshots that drive is a
// scratch folder, so the app's checks that a folder or a master file is there
// see what they would see on the rig.
import 'dart:io';

/// Maps `D:\...` paths onto [root] for every file and folder the app opens.
final class RigDrive extends IOOverrides {
  RigDrive(this.root);

  final String root;

  static const drive = r'D:\';

  String _local(String path) => path.startsWith(drive)
      ? '$root/D/${path.substring(drive.length).replaceAll(r'\', '/')}'
      : path;

  @override
  File createFile(String path) => super.createFile(_local(path));

  @override
  Directory createDirectory(String path) => super.createDirectory(_local(path));

  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      super.fseGetType(_local(path), followLinks);

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      super.fseGetTypeSync(_local(path), followLinks);

  /// Puts [paths] on the drive as files (empty: nothing reads their pixels).
  void put(Iterable<String> paths) {
    for (final path in paths) {
      final file = File(_local(path));
      file.parent.createSync(recursive: true);
      if (!file.existsSync()) file.createSync();
    }
  }
}
