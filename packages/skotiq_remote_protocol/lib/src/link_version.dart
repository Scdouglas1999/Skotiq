/// The rule that a client links only to a host of its own Skotiq release.
library;

import 'wire/api_error.dart';

/// The Skotiq release this build is. `version.yaml` is the source; the
/// version-consistency audit fails CI when this differs from it.
const String skotiqRelease = '8.2.1';

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

  /// Null when [host] and [client] are the same release; otherwise what is
  /// wrong and which side to update. [host] is null or empty when the host
  /// did not say.
  static LinkVersionMismatch? check({
    required String? host,
    String client = skotiqRelease,
  }) {
    final hostRelease = host?.trim() ?? '';
    final clientRelease = client.trim();
    if (hostRelease.isNotEmpty && hostRelease == clientRelease) return null;
    return LinkVersionMismatch(
      host: hostRelease.isEmpty ? null : hostRelease,
      client: clientRelease,
    );
  }
}

/// The side of a link that has to be updated.
enum LinkSide { host, client }

/// Host and client run different Skotiq releases.
class LinkVersionMismatch {
  const LinkVersionMismatch({required this.host, required this.client});

  /// The host's release; null when it did not say.
  final String? host;

  /// The client's release.
  final String client;

  /// The side running the older release, which is the one to update. Null
  /// when the two cannot be ordered (a development build's suffix).
  LinkSide? get older {
    final hostRelease = host;
    if (hostRelease == null) return LinkSide.host;
    final hostParts = _releaseParts(hostRelease);
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
    final hostRelease = host;
    final hostSays = hostRelease == null
        ? 'The host did not say which Skotiq it runs'
        : 'The host runs Skotiq $hostRelease';
    final update = switch (older) {
      LinkSide.host => 'Update the host to Skotiq $client',
      LinkSide.client => 'Update Skotiq on this device to $hostRelease',
      null => 'Install the same Skotiq release on both',
    };
    return '$hostSays and this device runs Skotiq $client. '
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
    return LinkVersionMismatch(
      host: host is String ? host : null,
      client: client,
    );
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
