/// Backend connection state.
///
/// Describes WebSocket session liveness, not OS-level connectivity. The
/// connection chip renders each state differently, so `connecting` (first
/// attempt) stays distinct from `reconnecting` (a previously-successful
/// connection dropped), and `error` (stopped attempting) from `disconnected`
/// (idle, backoff timer armed).
enum BackendConnectionState {
  /// Idle — not currently attempting a connection and not connected.
  /// Either disposed, or a backoff timer is armed before the next attempt.
  disconnected,

  /// First-time connect in progress (no prior successful attachment).
  /// Distinct from [reconnecting] so the UI says "Connecting" rather than
  /// "Reconnecting" on the initial handshake.
  connecting,

  /// WebSocket is open and the upgrade handshake completed successfully.
  connected,

  /// A prior connection dropped and the backend is retrying.
  reconnecting,

  /// Terminal failure mode (e.g. API version incompatibility). The backend
  /// stopped attempting; the user must reconfigure or relaunch. Emitting
  /// `error` is rare — most transient failures stay in [reconnecting] until
  /// the backoff window times out.
  error,
}
