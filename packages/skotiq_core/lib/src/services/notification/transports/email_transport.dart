// SMTP email transport.
//
// Why a hand-rolled SMTP implementation: pulling in a full mailer
// dependency (the `mailer` package or similar) is overkill — we send
// one short plain-text email per notification, never with attachments
// or HTML, never to more than one recipient. The protocol we need is a
// well-defined subset of RFC 5321:
//
//     EHLO
//     STARTTLS  (optional, gated on cfg.useTls)
//     EHLO      (after upgrade)
//     AUTH LOGIN (optional, gated on cfg.username.isNotEmpty)
//     MAIL FROM
//     RCPT TO
//     DATA + headers + body + `\r\n.\r\n`
//     QUIT
//
// Every step waits for a 2xx/3xx response and surfaces 4xx/5xx as a
// failure with the server's message. The socket I/O is fully async
// (Stream<List<int>> + StreamQueue-style buffering with a Completer
// per request).

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../../../models/notification/notification_categories.dart';
import '../../../models/notification/transport_configs.dart';
import 'notification_transport.dart';

/// Strategy hook so tests can swap the socket layer for an in-memory
/// fake. Defaults to real TCP / TLS sockets from `dart:io`.
typedef SmtpSocketOpener = Future<Socket> Function(String host, int port);
typedef SmtpSocketUpgrader =
    Future<SecureSocket> Function(Socket socket, {String? host});

Future<Socket> _defaultOpenSocket(String host, int port) =>
    Socket.connect(host, port);

Future<SecureSocket> _defaultUpgradeSocket(Socket socket, {String? host}) =>
    SecureSocket.secure(socket, host: host);

class EmailTransport extends NotificationTransport {
  EmailTransportConfig _config;
  final Duration _timeout;
  final SmtpSocketOpener _open;
  final SmtpSocketUpgrader _upgrade;

  EmailTransport({
    required EmailTransportConfig config,
    Duration timeout = const Duration(seconds: 20),
    SmtpSocketOpener? openSocket,
    SmtpSocketUpgrader? upgradeSocket,
  }) : _config = config,
       _timeout = timeout,
       _open = openSocket ?? _defaultOpenSocket,
       _upgrade = upgradeSocket ?? _defaultUpgradeSocket;

  @override
  NotificationTransportKind get kind => NotificationTransportKind.email;

  @override
  String get name => 'Email';

  @override
  bool get isConfigured => _config.isConfigured;

  void updateConfig(EmailTransportConfig config) {
    _config = config;
  }

  EmailTransportConfig get config => _config;

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    if (!isConfigured) {
      return NotificationResult.fail('Email not configured');
    }
    try {
      final result = await _runSmtpSession(
        category,
        title,
        body,
      ).timeout(_timeout);
      return result;
    } on TimeoutException {
      return NotificationResult.fail(
        'SMTP session timed out after ${_timeout.inSeconds}s',
      );
    } catch (e) {
      developer.log(
        '[Notifications/Email] SMTP failed: $e',
        name: 'EmailTransport',
        level: 1000,
        error: e,
      );
      return NotificationResult.fail(e.toString());
    }
  }

  Future<NotificationResult> _runSmtpSession(
    NotificationCategory category,
    String title,
    String body,
  ) async {
    final raw = await _open(_config.smtpHost, _config.smtpPort);
    final session = _SmtpSession(raw);
    try {
      await session.expectGreeting();
      await session.command('EHLO skotiq.local');

      Socket activeSocket = raw;
      if (_config.useTls) {
        await session.command('STARTTLS', expectedCodes: const [220]);
        final secure = await _upgrade(raw, host: _config.smtpHost);
        activeSocket = secure;
        session.swapSocket(secure);
        await session.command('EHLO skotiq.local');
      }

      if (_config.username.isNotEmpty) {
        await session.command('AUTH LOGIN', expectedCodes: const [334]);
        await session.command(
          base64.encode(utf8.encode(_config.username)),
          expectedCodes: const [334],
        );
        await session.command(
          base64.encode(utf8.encode(_config.password)),
          expectedCodes: const [235],
        );
      }

      await session.command('MAIL FROM:<${_config.fromAddress}>');
      await session.command('RCPT TO:<${_config.toAddress}>');
      await session.command('DATA', expectedCodes: const [354]);

      final mime = _buildMime(category, title, body);
      // RFC 5321 §4.5.2 — leading-dot stuffing: any line that starts with
      // `.` must be doubled to avoid being interpreted as end-of-data.
      final stuffed = mime
          .split('\r\n')
          .map((line) => line.startsWith('.') ? '.$line' : line)
          .join('\r\n');
      session.write('$stuffed\r\n.\r\n');
      await session.expectReply(const [250]);

      await session.command('QUIT', expectedCodes: const [221]);
      await activeSocket.close();
      return NotificationResult.ok();
    } catch (e) {
      try {
        await raw.close();
      } catch (_) {
        /* socket already closed */
      }
      rethrow;
    }
  }

  String _buildMime(NotificationCategory category, String title, String body) {
    final date = HttpDate.format(DateTime.now().toUtc());
    final subject = title.isEmpty ? '[Skotiq] ${category.label}' : title;
    final escapedSubject = subject.replaceAll('\r', ' ').replaceAll('\n', ' ');
    final buf = StringBuffer()
      ..writeln('From: ${_config.fromAddress}')
      ..writeln('To: ${_config.toAddress}')
      ..writeln('Subject: $escapedSubject')
      ..writeln('Date: $date')
      ..writeln('MIME-Version: 1.0')
      ..writeln('Content-Type: text/plain; charset=utf-8')
      ..writeln('Content-Transfer-Encoding: 8bit')
      ..writeln('X-Skotiq-Category: ${category.storageKey}')
      ..writeln('')
      ..writeln(body);
    // Normalise to CRLF — SMTP requires it.
    return buf.toString().replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
  }

  @override
  Future<void> dispose() async {
    // EmailTransport opens a fresh socket per send and closes it; nothing
    // to clean up here.
  }
}

/// Minimal line-oriented SMTP client. Internally buffers bytes from the
/// socket and dispatches each parsed line to a FIFO of waiters so
/// `expectReply` can be called sequentially without missing or
/// duplicating replies.
class _SmtpSession {
  Socket _socket;
  late StreamSubscription<List<int>> _subscription;
  final List<int> _buffer = [];
  final List<String> _pendingLines = [];
  final List<Completer<String>> _waiters = [];
  Object? _streamError;

  _SmtpSession(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: _onStreamError,
      onDone: _onStreamDone,
    );
  }

  void swapSocket(Socket newSocket) {
    _subscription.cancel();
    _socket = newSocket;
    _subscription = _socket.listen(
      _onData,
      onError: _onStreamError,
      onDone: _onStreamDone,
    );
  }

  void _onData(List<int> bytes) {
    _buffer.addAll(bytes);
    while (true) {
      final idx = _buffer.indexOf(0x0a); // LF
      if (idx < 0) return;
      final lineBytes = _buffer.sublist(0, idx);
      _buffer.removeRange(0, idx + 1);
      var line = utf8.decode(lineBytes, allowMalformed: true);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      _emitLine(line);
    }
  }

  void _emitLine(String line) {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      waiter.complete(line);
      return;
    }
    _pendingLines.add(line);
  }

  void _onStreamError(Object error) {
    _streamError = error;
    for (final w in _waiters) {
      w.completeError(error);
    }
    _waiters.clear();
  }

  void _onStreamDone() {
    final err = _streamError ?? StateError('SMTP socket closed unexpectedly');
    for (final w in _waiters) {
      w.completeError(err);
    }
    _waiters.clear();
  }

  Future<String> _nextLine() {
    if (_pendingLines.isNotEmpty) {
      return Future.value(_pendingLines.removeAt(0));
    }
    if (_streamError != null) {
      return Future.error(_streamError!);
    }
    final completer = Completer<String>();
    _waiters.add(completer);
    return completer.future;
  }

  Future<void> expectGreeting() => expectReply(const [220]);

  Future<void> command(
    String line, {
    List<int> expectedCodes = const [250],
  }) async {
    _socket.write('$line\r\n');
    await expectReply(expectedCodes);
  }

  void write(String s) => _socket.write(s);

  Future<void> expectReply(List<int> expectedCodes) async {
    final firstLine = await _nextLine();
    // Multi-line replies: "250-foo" continues, "250 foo" terminates.
    var line = firstLine;
    while (line.length >= 4 && line[3] == '-') {
      line = await _nextLine();
    }
    if (line.length < 3) {
      throw Exception('SMTP malformed reply: $firstLine');
    }
    final code = int.tryParse(line.substring(0, 3));
    if (code == null || !expectedCodes.contains(code)) {
      throw Exception('SMTP error: $firstLine');
    }
  }
}
