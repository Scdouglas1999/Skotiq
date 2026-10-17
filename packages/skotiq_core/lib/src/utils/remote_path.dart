/// The directory part of a path produced by the RIG, not by this machine.
///
/// `package:path`'s top-level `dirname` resolves against the local platform's
/// separator rules, so a Windows path that arrives over the wire — every
/// `reject_path` and `save_path` on a sequencer frame event from a Windows rig
/// — comes back as `.` when it is read on Linux. A paired phone, a headless
/// Linux appliance mirroring a Windows master, and this package's own tests all
/// read exactly those strings.
///
/// So the separator is taken from the path itself: whichever of `/` or `\`
/// appears last is the one that rig writes. Returns null when the path names no
/// directory at all (empty, or a bare filename), because inventing `.` would
/// point the operator at the app's working directory instead of his images.
String? parentDirectoryOf(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  // A leading separator IS the directory ("/x" lives in "/"), so index 0 is
  // kept while "no separator at all" is not.
  if (cut < 0) return null;
  if (cut == 0) return path.substring(0, 1);
  return path.substring(0, cut);
}
