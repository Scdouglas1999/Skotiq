/// Reading a host's `/api/info`, and the typed reasons a link cannot be made.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'link_version.dart';
import 'network_uri.dart';

/// Why this device cannot link to an address.
enum LinkProblemKind {
  /// Nothing answered: the host is off, asleep or on another network.
  unreachable,

  /// The computer answered that nothing listens on the port: Skotiq is not
  /// running there, or Remote access is off, or the port is wrong.
  refused,

  /// The address is not a Skotiq host: the name does not resolve, or what
  /// answered is something else.
  wrongAddress,

  /// A Skotiq host of another release answered.
  mismatch,
}

/// One reason a link cannot be made, with the sentence the operator reads.
/// Every surface that links (desktop, phone, the connection itself) shows
/// [message]; none words its own.
class LinkProblem {
  const LinkProblem.unreachable(this.address)
    : kind = LinkProblemKind.unreachable,
      mismatch = null,
      _nameNotFound = false;

  const LinkProblem.refused(this.address)
    : kind = LinkProblemKind.refused,
      mismatch = null,
      _nameNotFound = false;

  const LinkProblem.wrongAddress(this.address, {bool nameNotFound = false})
    : kind = LinkProblemKind.wrongAddress,
      mismatch = null,
      _nameNotFound = nameNotFound;

  const LinkProblem.mismatch(this.address, LinkVersionMismatch this.mismatch)
    : kind = LinkProblemKind.mismatch,
      _nameNotFound = false;

  final LinkProblemKind kind;

  /// `host:port` as the operator entered or discovered it.
  final String address;

  /// The two releases, for [LinkProblemKind.mismatch].
  final LinkVersionMismatch? mismatch;

  final bool _nameNotFound;

  String get message => switch (kind) {
    LinkProblemKind.unreachable =>
      'No answer from $address. Check that the host computer is on, awake '
          'and on the same network as this device.',
    LinkProblemKind.refused =>
      '$address answered, but Skotiq is not listening there. Start Skotiq '
          'on the host with Remote access on, and check the port.',
    LinkProblemKind.wrongAddress =>
      _nameNotFound
          ? 'The name in $address could not be found. Check the address.'
          : '$address answered, but it is not a Skotiq host. Check the '
                'address and the port.',
    LinkProblemKind.mismatch => mismatch!.message,
  };

  @override
  String toString() => message;
}

/// What reading a host's `/api/info` gave.
sealed class HostInfoRead {
  const HostInfoRead();

  /// Why this device cannot link to the host, or null when it can.
  LinkProblem? get problem;
}

/// A Skotiq host answered.
final class HostInfoAnswer extends HostInfoRead {
  const HostInfoAnswer({
    required this.address,
    required this.info,
    required this.release,
  });

  final String address;

  /// The `/api/info` document.
  final Map<String, dynamic> info;

  /// The Skotiq release the host says it runs.
  final String release;

  @override
  LinkProblem? get problem {
    final mismatch = LinkVersion.check(host: release);
    return mismatch == null ? null : LinkProblem.mismatch(address, mismatch);
  }
}

/// No Skotiq host answered.
final class HostInfoFailure extends HostInfoRead {
  const HostInfoFailure(this.problem, {this.httpStatus});

  @override
  final LinkProblem problem;

  /// The status of an answer that was not a Skotiq info document; null when
  /// nothing answered.
  final int? httpStatus;
}

/// `GET /api/info` on a host, with this build's release in the request.
///
/// The one place that decides between "unreachable", "refused", "wrong
/// address" and a host that answered; the release comparison is run only on a
/// release the host sent.
Future<HostInfoRead> readHostInfo({
  required String scheme,
  required String host,
  required int port,
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 5),
  http.Client? client,
}) async {
  final address = '$host:$port';
  final uri = buildSkotiqServerUri(
    scheme: scheme,
    host: host,
    port: port,
    pathAndQuery: '/api/info',
  );
  final requestHeaders = {...headers, LinkVersion.header: skotiqRelease};
  final http.Response response;
  try {
    response =
        await (client == null
                ? http.get(uri, headers: requestHeaders)
                : client.get(uri, headers: requestHeaders))
            .timeout(timeout);
  } catch (error) {
    return HostInfoFailure(linkProblemFromError(error, address));
  }
  if (response.statusCode != 200) {
    return HostInfoFailure(
      LinkProblem.wrongAddress(address),
      httpStatus: response.statusCode,
    );
  }
  final Object? info;
  try {
    info = jsonDecode(response.body);
  } on FormatException {
    return HostInfoFailure(LinkProblem.wrongAddress(address));
  }
  final release = info is Map<String, dynamic> ? info['version'] : null;
  if (info is! Map<String, dynamic> ||
      release is! String ||
      release.trim().isEmpty) {
    return HostInfoFailure(LinkProblem.wrongAddress(address));
  }
  return HostInfoAnswer(address: address, info: info, release: release.trim());
}

/// The [LinkProblem] a failed request to [address] stands for.
LinkProblem linkProblemFromError(Object error, String address) {
  if (error is TimeoutException) return LinkProblem.unreachable(address);
  if (error is SocketException) {
    final text = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    if (text.contains('failed host lookup') ||
        text.contains('name or service not known') ||
        text.contains('no address associated') ||
        text.contains('nodename nor servname')) {
      return LinkProblem.wrongAddress(address, nameNotFound: true);
    }
    // ECONNREFUSED: 111 on Linux and Android, 61 on macOS and iOS, 10061 on
    // Windows.
    final code = error.osError?.errorCode;
    if (code == 111 ||
        code == 61 ||
        code == 10061 ||
        text.contains('refused')) {
      return LinkProblem.refused(address);
    }
    return LinkProblem.unreachable(address);
  }
  if (error is TlsException || error is FormatException) {
    return LinkProblem.wrongAddress(address);
  }
  if (error is http.ClientException) {
    final text = error.message.toLowerCase();
    if (text.contains('refused')) return LinkProblem.refused(address);
    if (text.contains('failed host lookup')) {
      return LinkProblem.wrongAddress(address, nameNotFound: true);
    }
  }
  return LinkProblem.unreachable(address);
}
