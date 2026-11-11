import 'dart:io';

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show kDefaultHeadlessPort;

class ManualServerEndpoint {
  final String host;
  final int port;
  final String scheme;

  const ManualServerEndpoint({
    required this.host,
    required this.port,
    required this.scheme,
  });

  String get authority => Uri(scheme: scheme, host: host, port: port).authority;
}

/// Parses the address accepted by the mobile connection screen.
///
/// Hostnames and IPv4 addresses may use `host:port`. IPv6 literals use their
/// bare form for the default port, or the standard `[address]:port` form for a
/// custom port. Pasted HTTP(S) URLs are also accepted because the desktop's
/// Remote Access panel presents the server address as a URL.
ManualServerEndpoint parseManualServerEndpoint(
  String input, {
  int defaultPort = kDefaultHeadlessPort,
}) {
  final value = input.trim();
  if (value.isEmpty) {
    throw const FormatException('Please enter a server address');
  }

  if (value.startsWith('http://') || value.startsWith('https://')) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Enter a server URL without a path, query, or sign-in details',
      );
    }
    final port = uri.hasPort ? uri.port : defaultPort;
    _validatePort(port);
    return ManualServerEndpoint(host: uri.host, port: port, scheme: uri.scheme);
  }

  if (value.contains(RegExp(r'\s|/'))) {
    throw const FormatException('Enter a valid host name or IP address');
  }

  if (value.startsWith('[')) {
    final closingBracket = value.indexOf(']');
    if (closingBracket <= 1) {
      throw const FormatException('Enter a valid bracketed IPv6 address');
    }
    final host = value.substring(1, closingBracket);
    _validateIpv6(host);
    final remainder = value.substring(closingBracket + 1);
    final port = remainder.isEmpty ? defaultPort : _parsePortSuffix(remainder);
    return ManualServerEndpoint(host: host, port: port, scheme: 'http');
  }

  final colonCount = ':'.allMatches(value).length;
  if (colonCount > 1) {
    _validateIpv6(value);
    return ManualServerEndpoint(host: value, port: defaultPort, scheme: 'http');
  }

  if (colonCount == 1) {
    final separator = value.indexOf(':');
    final host = value.substring(0, separator);
    if (host.isEmpty) {
      throw const FormatException('Enter a valid host name or IP address');
    }
    final port = _parsePortSuffix(value.substring(separator));
    return ManualServerEndpoint(host: host, port: port, scheme: 'http');
  }

  return ManualServerEndpoint(host: value, port: defaultPort, scheme: 'http');
}

int _parsePortSuffix(String suffix) {
  if (!suffix.startsWith(':') || suffix.length == 1) {
    throw const FormatException('Enter a port between 1 and 65535');
  }
  final port = int.tryParse(suffix.substring(1));
  if (port == null) {
    throw const FormatException('Enter a numeric port between 1 and 65535');
  }
  _validatePort(port);
  return port;
}

void _validatePort(int port) {
  if (port < 1 || port > 65535) {
    throw const FormatException('Enter a port between 1 and 65535');
  }
}

void _validateIpv6(String host) {
  final parsed = InternetAddress.tryParse(host);
  if (parsed == null || parsed.type != InternetAddressType.IPv6) {
    throw const FormatException('Enter a valid IPv6 address');
  }
}
