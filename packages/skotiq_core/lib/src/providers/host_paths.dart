import 'host_role.dart';

/// Paths the imaging host wrote (frames, masters), as files this process can
/// open.
abstract interface class HostPaths {
  /// [hostPath] as a file on this computer, or null when the host's files are
  /// on another machine and only the host can open it.
  String? local(String hostPath);
}

/// The imaging host is this process: its paths are this computer's.
final class _SameComputerPaths implements HostPaths {
  const _SameComputerPaths();

  @override
  String? local(String hostPath) => hostPath;
}

/// A linked host's paths name files on that machine.
final class _OtherComputerPaths implements HostPaths {
  const _OtherComputerPaths();

  @override
  String? local(String hostPath) => null;
}

/// Where the files the imaging host wrote can be opened from here.
final hostPathsProvider = hostRoleProvider<HostPaths>(
  here: (ref) => const _SameComputerPaths(),
  linked: (ref, host) => const _OtherComputerPaths(),
  name: 'hostPathsProvider',
);
