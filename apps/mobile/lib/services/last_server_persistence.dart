/// Whether a successful connect should be written as the startup last server.
///
/// The relay tunnel listens on 127.0.0.1 at an ephemeral port. Saving that
/// endpoint makes the next launch retry a port that is gone. Any other host
/// is still the operator's server, even when a tunnel is open for a different
/// connect.
bool shouldPersistConnectedServer({
  required String host,
  required int port,
  required String? tunnelHost,
  required int? tunnelPort,
}) {
  if (tunnelHost == null || tunnelPort == null) return true;
  return host != tunnelHost || port != tunnelPort;
}
