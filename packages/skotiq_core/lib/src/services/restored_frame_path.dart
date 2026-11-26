import 'package:path/path.dart' as p;

/// Where a frame graded into the reject folder goes back to when the
/// operator restores it: the folder the reject folder sits in.
///
/// [rejectFolder] is the reject-folder setting: empty for the default
/// `Reject`, a path relative to the frame's folder, or an absolute path.
/// The sequencer (`resolve_reject_dir`) uses an absolute folder only when it
/// lies inside the frame's folder and `Reject` otherwise; an absolute folder
/// says nothing of where the frame came from, so only `Reject` is undone
/// then. Null when the frame is not in the reject folder.
String? restoredFramePath(String filePath, {String? rejectFolder}) {
  final folder = p.normalize(p.dirname(filePath));
  final configured = rejectFolder?.trim() ?? '';
  final relative = configured.isEmpty || p.isAbsolute(configured)
      ? 'Reject'
      : configured;
  final parts = p.split(p.normalize(relative));
  final folderParts = p.split(folder);
  if (folderParts.length <= parts.length) return null;
  final tail = folderParts.sublist(folderParts.length - parts.length);
  for (var i = 0; i < parts.length; i++) {
    if (tail[i] != parts[i]) return null;
  }
  final original = p.joinAll(
    folderParts.sublist(0, folderParts.length - parts.length),
  );
  return p.join(original, p.basename(filePath));
}
