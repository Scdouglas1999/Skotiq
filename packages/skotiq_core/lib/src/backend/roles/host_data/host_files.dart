import 'package:skotiq_core/skotiq_core.dart';

/// The file system of a linked imaging host: the folders it will write to and
/// the files it can send to this device.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostFiles {
  Future<RemoteDirectoryListing> browseRemoteDirectories({String? path});
}
