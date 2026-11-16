import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How a PHD2 event-socket probe ended.
///
/// The distinction between [unidentified] and [unreachable] exists because a
/// bare TCP connect proves only that *something* holds the port. Reporting
/// "PHD2 answered" off a successful connect is a claim the probe never
/// established, and reporting "no response" when the socket did open is the
/// opposite lie.
enum Phd2ProbeOutcome {
  /// A PHD2 event server accepted the socket and announced its version.
  identified,

  /// The socket opened but nothing announced itself as PHD2 before the
  /// deadline.
  unidentified,

  /// The socket could not be opened at all.
  unreachable,

  /// The imaging host accepted the port probe but predates the handshake
  /// endpoint, so its PHD2 version is unknown rather than absent.
  reachableUnverified,
}

/// Result of a PHD2 event-server handshake.
class Phd2ProbeResult {
  const Phd2ProbeResult({
    required this.outcome,
    this.version,
    this.subVersion,
    this.profile,
    this.error,
  });

  final Phd2ProbeOutcome outcome;

  /// `PHDVersion` from PHD2's `Version` event (e.g. `2.6.13`).
  final String? version;

  /// `PHDSubver` from the same event; usually empty on release builds.
  final String? subVersion;

  /// Name of the PHD2 equipment profile that is currently selected.
  final String? profile;

  /// Socket-level failure text when [outcome] is [Phd2ProbeOutcome.unreachable].
  final String? error;

  bool get isPhd2 => outcome == Phd2ProbeOutcome.identified;

  /// PHD2 renders `2.6.13` + subver `dev4` as `2.6.13dev4`.
  String? get fullVersion {
    final v = version;
    if (v == null || v.isEmpty) return null;
    final sub = subVersion;
    return (sub == null || sub.isEmpty) ? v : '$v$sub';
  }

  Map<String, dynamic> toJson() => {
    'outcome': outcome.name,
    if (version != null) 'version': version,
    if (subVersion != null) 'subVersion': subVersion,
    if (profile != null) 'profile': profile,
    if (error != null) 'error': error,
  };

  factory Phd2ProbeResult.fromJson(Map<String, dynamic> json) {
    final name = json['outcome'];
    final outcome = Phd2ProbeOutcome.values.firstWhere(
      (o) => o.name == name,
      orElse: () => Phd2ProbeOutcome.unidentified,
    );
    return Phd2ProbeResult(
      outcome: outcome,
      version: json['version'] as String?,
      subVersion: json['subVersion'] as String?,
      profile: json['profile'] as String?,
      error: json['error'] as String?,
    );
  }
}

/// Mirrors `normalize_phd2_tcp_host` in the native PHD2 client: on Windows
/// `localhost` frequently resolves to `::1` while PHD2 listens on IPv4 only,
/// so an un-normalised probe reports a healthy PHD2 as absent.
String normalizePhd2ProbeHost(String host) {
  switch (host.trim().toLowerCase()) {
    case '':
    case 'localhost':
    case '::1':
      return '127.0.0.1';
    default:
      return host.trim();
  }
}

/// JSON-RPC id used for the one `get_profile` call the probe makes. PHD2
/// echoes the id back, which is how the response is told apart from the
/// asynchronous event stream sharing the same socket.
const int _profileRequestId = 9_100;

/// Open PHD2's event server on [host]:[port], read the `Version` event it
/// sends to every connecting client, and ask which equipment profile is
/// selected.
///
/// Read-only: PHD2's event server accepts multiple clients and `get_profile`
/// changes nothing, so this is safe to run while a session is guiding.
Future<Phd2ProbeResult> probePhd2({
  required String host,
  required int port,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final target = normalizePhd2ProbeHost(host);

  final Socket socket;
  try {
    socket = await Socket.connect(target, port, timeout: timeout);
  } on SocketException catch (e) {
    return Phd2ProbeResult(
      outcome: Phd2ProbeOutcome.unreachable,
      error: e.osError?.message ?? e.message,
    );
  } on ArgumentError catch (e) {
    return Phd2ProbeResult(
      outcome: Phd2ProbeOutcome.unreachable,
      error: e.message?.toString() ?? '$e',
    );
  }

  final completer = Completer<Phd2ProbeResult>();
  String? version;
  String? subVersion;
  String? profile;
  var askedForProfile = false;

  Timer? deadline;
  StreamSubscription<String>? lines;

  void finish() {
    if (completer.isCompleted) return;
    deadline?.cancel();
    unawaited(lines?.cancel());
    socket.destroy();
    completer.complete(
      Phd2ProbeResult(
        outcome: version == null
            ? Phd2ProbeOutcome.unidentified
            : Phd2ProbeOutcome.identified,
        version: version,
        subVersion: subVersion,
        profile: profile,
      ),
    );
  }

  deadline = Timer(timeout, finish);

  lines = socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (line.trim().isEmpty) return;
          final Object? decoded;
          try {
            decoded = jsonDecode(line);
          } on FormatException {
            // A non-JSON line means this is not PHD2's event server; keep
            // listening so a slow banner protocol still gets its chance.
            return;
          }
          if (decoded is! Map<String, dynamic>) return;

          if (decoded['Event'] == 'Version') {
            version = decoded['PHDVersion'] as String?;
            subVersion = decoded['PHDSubver'] as String?;
            if (!askedForProfile) {
              askedForProfile = true;
              try {
                socket.write(
                  '${jsonEncode({'method': 'get_profile', 'id': _profileRequestId})}\r\n',
                );
              } on SocketException {
                // The version is already in hand; a write failure only costs
                // the profile name.
                finish();
              }
            }
            return;
          }

          if (decoded['id'] == _profileRequestId) {
            final result = decoded['result'];
            if (result is Map && result['name'] is String) {
              profile = result['name'] as String;
            }
            // Whether PHD2 answered with a profile or a JSON-RPC error, the
            // handshake is over.
            finish();
          }
        },
        onError: (_) => finish(),
        onDone: finish,
        cancelOnError: true,
      );

  return completer.future;
}
