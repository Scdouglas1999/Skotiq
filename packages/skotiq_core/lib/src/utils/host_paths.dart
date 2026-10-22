import 'package:path/path.dart' as path;

/// The path style of the machine that owns [hostPath]: Windows when it has a
/// drive letter or a backslash, posix otherwise. A linked client must build
/// every path the host will write in this style, never its own.
path.Context hostPathContext(String hostPath) {
  final isWindowsPath =
      hostPath.contains(r'\') || RegExp(r'^[A-Za-z]:').hasMatch(hostPath);
  return path.Context(
    style: isWindowsPath ? path.Style.windows : path.Style.posix,
    current: isWindowsPath ? r'C:\' : '/',
  );
}
