/// The rule that a client links only to a host of its own Skotiq release.
library;

import 'wire/api_error.dart';

/// The Skotiq release this build is. `version.yaml` is the source; the
/// version-consistency audit fails CI when this differs from it.
const String skotiqRelease = '9.0.0';

/// A client links only to a host of the same Skotiq release.
///
/// Host and client exchange runtime state, events and records whose shapes
/// change between releases, and neither side reads another release's shapes.
/// Both machines update together, so the release string is the whole check.
abstract final class LinkVersion {
  /// Request header naming the client's release.
  static const header = 'x-skotiq-version';

  /// The WebSocket upgrade's query parameter naming the client's release,
  /// for clients that cannot set a header on the upgrade.
  static const queryParameter = 'version';

  /// [ApiErrorBody.code] of the host's refusal of a request from another
  /// release.
  static const mismatchCode = 'version_mismatch';

  /// [ApiErrorBody.code] of the host's refusal of an API request that does
  /// not say which release sent it.
  static const releaseRequiredCode = 'release_required';

  /// Null when [host] and [client] are the same release; otherwise what is
  /// wrong and which side to update. [host] is the release a host actually
  /// reported: a host that has not answered is unreachable, not mismatched
  /// (see `readHostInfo`).
  static LinkVersionMismatch? check({
    required String host,
    String client = skotiqRelease,
  }) {
    final hostRelease = host.trim();
    final clientRelease = client.trim();
    if (hostRelease == clientRelease) return null;
    return LinkVersionMismatch(host: hostRelease, client: clientRelease);
  }

  /// Whether a client of another release may still call [path]: the host's
  /// identity, so each side can say what the other runs, and the update
  /// routes, so a newer client can bring an older host up to its release.
  /// Nothing else is shared between releases.
  static bool openToOtherReleases(String path) =>
      path == '/api/info' ||
      path == '/api/system/version' ||
      path.startsWith('/api/system/update/');
}

/// The side of a link that has to be updated.
enum LinkSide { host, client }

/// Host and client run different Skotiq releases.
class LinkVersionMismatch {
  const LinkVersionMismatch({required this.host, required this.client});

  /// The host's release.
  final String host;

  /// The client's release.
  final String client;

  /// The side running the older release, which is the one to update. Null
  /// when the two cannot be ordered (a development build's suffix).
  LinkSide? get older {
    final hostParts = _releaseParts(host);
    final clientParts = _releaseParts(client);
    if (hostParts == null || clientParts == null) return null;
    for (var i = 0; i < 3; i++) {
      if (hostParts[i] < clientParts[i]) return LinkSide.host;
      if (hostParts[i] > clientParts[i]) return LinkSide.client;
    }
    return null;
  }

  /// One sentence for the operator naming both releases and which side to
  /// update.
  String get message {
    final update = switch (older) {
      LinkSide.host => 'Update the host to Skotiq $client',
      LinkSide.client => 'Update Skotiq on this device to $host',
      null => 'Install the same Skotiq release on both',
    };
    return 'The host runs Skotiq $host and this device runs Skotiq $client. '
        '$update, then connect again.';
  }

  /// The host's refusal of a request from [client].
  ApiErrorBody toErrorBody({String? requestId}) => ApiErrorBody(
    code: LinkVersion.mismatchCode,
    message: message,
    layout: ApiErrorLayout.codeAsError,
    requestId: requestId,
    details: {'hostVersion': host, 'clientVersion': client},
  );

  /// The mismatch the body of a host's refusal ([toErrorBody]) describes;
  /// null for any other error body.
  static LinkVersionMismatch? fromErrorJson(Map<String, dynamic> json) {
    if (json['code'] != LinkVersion.mismatchCode) return null;
    final client = json['clientVersion'];
    if (client is! String) return null;
    final host = json['hostVersion'];
    if (host is! String) return null;
    return LinkVersionMismatch(host: host, client: client);
  }

  @override
  bool operator ==(Object other) =>
      other is LinkVersionMismatch &&
      other.host == host &&
      other.client == client;

  @override
  int get hashCode => Object.hash(host, client);

  @override
  String toString() => message;
}

/// `major.minor.patch` of a plain release string; null for anything else.
List<int>? _releaseParts(String release) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(release);
  if (match == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
}
