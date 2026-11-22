/// The TCP ports a port field accepts.
///
/// A field checks what was typed against its range; the stored setting is
/// not bounded, so a port saved outside the range is left as it is.
final class PortRange {
  const PortRange(this.min, this.max) : assert(min <= max);

  /// Any TCP port.
  static const any = PortRange(1, 65535);

  /// The web server's port. The operator types an unprivileged one, so the
  /// server can bind it without root.
  static const webServer = PortRange(1024, 65535);

  final int min;
  final int max;

  bool contains(int port) => port >= min && port <= max;
}
