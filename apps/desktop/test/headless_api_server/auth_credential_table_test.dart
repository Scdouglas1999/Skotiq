import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api_server.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_remote_protocol/wire.dart';

import '../headless_api/handler_test_helpers.dart';

/// What the host answers each way of presenting a credential, on each class
/// of route, pinned in `fixtures/auth_credential_table.json`: the status and
/// body of every reply, and for the paired token whether the device was
/// recorded as seen. A row is a sequence of requests against a fresh server,
/// so the bad-credential limiter's count shows in the replies too.
/// `SKOTIQ_RECORD_REPLIES=1` rewrites the fixture.
final _fixture = File(
  'test/headless_api_server/fixtures/auth_credential_table.json',
);

const _release = '2.5.0';
const _tokens = {
  'admin': 'admin-token-0123456789',
  'view': 'view-token-0123456789',
  'control': 'control-token-0123456789',
  'mount': 'mount-token-0123456789',
  'paired': 'paired-session-token-abcdefgh',
  'bad': 'not-a-token-0123456789',
};

/// One request. [bearer] names a token sent as `Authorization: Bearer`;
/// [header] is a raw Authorization value; [cookieOf] sends the session
/// cookie minted for that token (with its CSRF header when [csrf]);
/// [query] is added to the path, `{ticket:<token>}` minting a ticket with
/// that token first and `{<token>}` standing for the token itself.
class _Step {
  const _Step(
    this.method,
    this.path, {
    this.bearer,
    this.header,
    this.cookieOf,
    this.csrf = false,
    this.query = const {},
    this.version = true,
    this.times = 1,
  });

  final String method;
  final String path;
  final String? bearer;
  final String? header;
  final String? cookieOf;
  final bool csrf;
  final Map<String, String> query;
  final bool version;
  final int times;

  bool get isWebSocket =>
      path == '/events' || path == '/api/ws' || path == '/ws/live-view';
}

const _status = '/api/status';
const _park = '/api/mount/park';
const _reload = '/api/catalog/reload';
const _sse = '/api/run-watch/events';

_Step _get(
  String path, {
  String? bearer,
  Map<String, String> query = const {},
}) => _Step('GET', path, bearer: bearer, query: query);

final Map<String, List<_Step>> _rows = {
  // Public routes need nothing.
  'public.none': [_get('/api/info')],
  'public.bad_bearer': [_get('/api/info', bearer: 'bad')],

  // Header bearer on each route class.
  for (final (name, method, path) in [
    ('view', 'GET', _status),
    ('control', 'POST', _park),
    ('admin', 'POST', _reload),
  ]) ...{
    '$name.none': [_Step(method, path)],
    for (final token in ['admin', 'view', 'control', 'mount', 'paired', 'bad'])
      '$name.bearer_$token': [_Step(method, path, bearer: token)],
    '$name.malformed_header': [_Step(method, path, header: 'Token abc')],
    '$name.malformed_header_with_cookie': [
      _Step(method, path, header: 'Token abc', cookieOf: 'admin', csrf: true),
    ],
    '$name.cookie_view': [_Step(method, path, cookieOf: 'view', csrf: true)],
    '$name.cookie_control_no_csrf': [_Step(method, path, cookieOf: 'control')],
    '$name.cookie_control_csrf': [
      _Step(method, path, cookieOf: 'control', csrf: true),
    ],
    '$name.cookie_bad_csrf_then_bearer': [
      _Step(method, path, cookieOf: 'control', bearer: 'view'),
    ],
    '$name.access_token_not_honored': [
      _Step(method, path, query: {'access_token': '{admin}'}),
    ],
    '$name.query_token_not_honored': [
      _Step(method, path, query: {'token': '{admin}'}),
    ],
    '$name.no_version': [_Step(method, path, bearer: 'admin', version: false)],
  },
  'logout.cookie_no_csrf': [
    const _Step('POST', '/api/auth/logout', cookieOf: 'view'),
  ],

  // The event stream takes `?access_token=`.
  'sse.access_token_view': [
    _get(_sse, query: {'access_token': '{view}'}),
  ],
  'sse.access_token_bad': [
    _get(_sse, query: {'access_token': '{bad}'}),
  ],
  'sse.access_token_mount': [
    _get(_sse, query: {'access_token': '{mount}'}),
  ],
  'sse.access_token_over_header': [
    _get(_sse, bearer: 'view', query: {'access_token': '{bad}'}),
  ],
  'sse.bearer_view': [_get(_sse, bearer: 'view')],

  // Sockets: ticket, `?token=`, header.
  for (final ws in ['/events', '/api/ws']) ...{
    'ws$ws.none': [_get(ws)],
    'ws$ws.bearer_view': [_get(ws, bearer: 'view')],
    'ws$ws.bearer_mount': [_get(ws, bearer: 'mount')],
    'ws$ws.ticket_view': [
      _get(ws, query: {'ticket': '{ticket:view}'}),
    ],
    'ws$ws.ticket_reused': [
      _get(ws, query: {'ticket': '{ticket:view}'}),
      _get(ws, query: {'ticket': '{last-ticket}'}),
    ],
    'ws$ws.ticket_bad': [
      _get(ws, query: {'ticket': 'nope'}),
    ],
    'ws$ws.ticket_bad_with_bearer': [
      _get(ws, bearer: 'admin', query: {'ticket': 'nope'}),
    ],
    'ws$ws.ticket_empty_with_bearer': [
      _get(ws, bearer: 'view', query: {'ticket': ''}),
    ],
    'ws$ws.token_view': [
      _get(ws, query: {'token': '{view}'}),
    ],
    'ws$ws.token_paired': [
      _get(ws, query: {'token': '{paired}'}),
    ],
    'ws$ws.token_bad': [
      _get(ws, query: {'token': '{bad}'}),
    ],
    'ws$ws.token_bad_with_bearer': [
      _get(ws, bearer: 'view', query: {'token': '{bad}'}),
    ],
    'ws$ws.token_mount': [
      _get(ws, query: {'token': '{mount}'}),
    ],
    'ws$ws.token_mount_with_bearer': [
      _get(ws, bearer: 'view', query: {'token': '{mount}'}),
    ],
    'ws$ws.token_empty_with_bearer': [
      _get(ws, bearer: 'view', query: {'token': ''}),
    ],
    'ws$ws.ticket_over_token': [
      _get(ws, query: {'ticket': '{ticket:view}', 'token': '{bad}'}),
    ],
    'ws$ws.token_no_version': [
      const _Step('GET', '/events', query: {'token': '{view}'}, version: false),
    ],
  },
  'ws.token_view_version_query': [
    _get('/events', query: {'token': '{view}', 'version': _release}),
  ],

  // The bad-credential limiter.
  'limit.bearer_bad_x30_then_admin': [
    const _Step('GET', _status, bearer: 'bad', times: 30),
    _get(_status, bearer: 'admin'),
  ],
  'limit.bearer_bad_x29_then_admin_then_bad': [
    const _Step('GET', _status, bearer: 'bad', times: 29),
    _get(_status, bearer: 'admin'),
    const _Step('GET', _status, bearer: 'bad', times: 2),
  ],
  'limit.bearer_scope_denied_x31': [
    const _Step('POST', _park, bearer: 'view', times: 31),
  ],
  'limit.token_bad_x30_then_admin': [
    const _Step('GET', '/events', query: {'token': '{bad}'}, times: 30),
    _get(_status, bearer: 'admin'),
  ],
  'limit.token_mount_x30_then_admin': [
    const _Step('GET', '/events', query: {'token': '{mount}'}, times: 30),
    _get(_status, bearer: 'admin'),
  ],
  'limit.bearer_bad_x30_then_token_view': [
    const _Step('GET', _status, bearer: 'bad', times: 30),
    _get('/events', query: {'token': '{view}'}),
  ],
  'limit.ticket_bad_x31_then_admin': [
    const _Step('GET', '/events', query: {'ticket': 'nope'}, times: 31),
    _get(_status, bearer: 'admin'),
  ],
  'limit.access_token_bad_x30_then_admin': [
    _Step('GET', _sse, query: const {'access_token': '{bad}'}, times: 30),
    _get(_status, bearer: 'admin'),
  ],
  'limit.cookie_csrf_missing_x31': [
    const _Step('POST', _park, cookieOf: 'control', times: 31),
  ],

  // Whether the paired device is recorded as seen.
  'seen.paired_bearer_scope_denied': [_Step('POST', _park, bearer: 'paired')],
  'seen.paired_ws_token': [
    _get('/events', query: {'token': '{paired}'}),
  ],
  'seen.paired_sse_access_token': [
    _get(_sse, query: {'access_token': '{paired}'}),
  ],
};

class _Server {
  _Server(this.server, this.database, this.pairing, this.container);

  final HeadlessApiServer server;
  final PairingDatabase database;
  final PairingService pairing;
  final ProviderContainer container;
  final client = HttpClient();
  final cookies = <String, ({String cookie, String csrf})>{};
  String? lastTicket;

  Uri get base => Uri.parse('http://127.0.0.1:${server.actualPort}');

  static Future<_Server> start() async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    await database.addPairedDevice(
      deviceId: 'phone-1',
      deviceName: 'Pixel',
      sessionToken: _tokens['paired']!,
      deviceType: 'android',
      expiresAt: DateTime.now().add(const Duration(days: 30)),
      authGrantSpec: 'view',
    );
    final pairing = PairingService(database: database);
    final container = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: _release, buildNumber: 5),
        ),
      ],
    );
    final server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: _tokens['admin'],
      scopedAuthTokens: {
        _tokens['view']!: HeadlessTokenScope.view,
        _tokens['control']!: HeadlessTokenScope.control,
      },
      fineGrainedAuthTokens: {
        _tokens['mount']!: HeadlessAuthGrant.forResources({
          ApiResource.mount: HeadlessAccessLevel.control,
        }),
      },
      pairingService: pairing,
    );
    await server.start();
    return _Server(server, database, pairing, container);
  }

  Future<void> stop() async {
    client.close(force: true);
    await server.stop();
    await pairing.close();
    container.dispose();
  }

  Future<String> _ticket(String token) async {
    final reply = await _send(
      _Step('POST', '/api/ws/ticket', bearer: token),
      record: false,
    );
    final body = reply['body'];
    if (body is! Map) throw StateError('ticket mint: $reply');
    return lastTicket = body['ticket'] as String;
  }

  Future<({String cookie, String csrf})> _cookie(String token) async {
    final known = cookies[token];
    if (known != null) return known;
    final request = await client.openUrl(
      'POST',
      base.replace(path: '/api/auth/cookie'),
    );
    request.headers
      ..set(LinkVersion.header, _release)
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${_tokens[token]}')
      ..contentType = ContentType.json;
    request.contentLength = 2;
    request.write('{}');
    final response = await request.close();
    final body =
        jsonDecode(await response.transform(utf8.decoder).join()) as Map;
    final cookie = response.cookies.firstWhere(
      (c) => c.name == 'skotiq_session',
    );
    return cookies[token] = (
      cookie: '${cookie.name}=${cookie.value}',
      csrf: body['csrfToken'] as String,
    );
  }

  Future<Map<String, Object?>> _send(_Step step, {bool record = true}) async {
    final query = <String, String>{};
    for (final MapEntry(:key, :value) in step.query.entries) {
      final ticket = RegExp(r'^\{ticket:(\w+)\}$').firstMatch(value);
      final token = RegExp(r'^\{(\w+)\}$').firstMatch(value);
      if (ticket != null) {
        query[key] = await _ticket(ticket.group(1)!);
      } else if (value == '{last-ticket}') {
        query[key] = lastTicket!;
      } else if (token != null) {
        query[key] = _tokens[token.group(1)!]!;
      } else {
        query[key] = value;
      }
    }
    final cookie = step.cookieOf == null ? null : await _cookie(step.cookieOf!);
    final uri = base.replace(
      path: step.path,
      queryParameters: query.isEmpty ? null : query,
    );
    final request = await client.openUrl(step.method, uri);
    request.persistentConnection = false;
    if (step.version) request.headers.set(LinkVersion.header, _release);
    if (step.bearer != null) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${_tokens[step.bearer]}',
      );
    }
    if (step.header != null) {
      request.headers.set(HttpHeaders.authorizationHeader, step.header!);
    }
    if (cookie != null) {
      request.headers.set(HttpHeaders.cookieHeader, cookie.cookie);
      if (step.csrf) request.headers.set('X-Skotiq-CSRF', cookie.csrf);
    }
    if (step.isWebSocket) {
      request.headers
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, 'websocket')
        ..set('sec-websocket-version', '13')
        ..set('sec-websocket-key', base64.encode(List.filled(16, 7)));
    }
    if (step.method != 'GET') {
      request.headers.contentType = ContentType.json;
      request.contentLength = 2;
      request.write('{}');
    }
    final response = await request.close();
    final status = response.statusCode;
    if (status == HttpStatus.switchingProtocols) {
      (await response.detachSocket()).destroy();
      return {'status': status};
    }
    final type = response.headers.contentType?.mimeType;
    if (type == 'text/event-stream') {
      (await response.detachSocket()).destroy();
      return {'status': status};
    }
    final text = await response.transform(utf8.decoder).join();
    // The identity answer carries this run's instance id and port.
    if (step.path == '/api/info') return {'status': status};
    Object? body;
    try {
      body = _withoutRequestIds(jsonDecode(text));
    } on FormatException {
      body = text;
    }
    return {'status': status, 'body': body};
  }

  Future<List<Object?>> run(List<_Step> steps) async {
    final replies = <Object?>[];
    for (final step in steps) {
      for (var i = 0; i < step.times; i++) {
        final reply = await _send(step);
        if (step.times == 1 || i == 0 || i >= step.times - 2) {
          replies.add({if (step.times > 1) 'attempt': i + 1, ...reply});
        }
      }
    }
    return replies;
  }

  Future<bool> pairedSeen() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final row = await database.getPairedDevice('phone-1');
      if (row?.lastConnectedAt != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return false;
  }
}

Object? _withoutRequestIds(Object? value) => switch (value) {
  Map() => {
    for (final e in value.entries)
      if (e.key != 'requestId') '${e.key}': _withoutRequestIds(e.value),
  },
  List() => [for (final v in value) _withoutRequestIds(v)],
  _ => value,
};

void main() {
  final record = Platform.environment['SKOTIQ_RECORD_REPLIES'] == '1';
  final recorded = <String, Object?>{};
  final expected = record
      ? const <String, Object?>{}
      : jsonDecode(_fixture.readAsStringSync()) as Map<String, Object?>;

  tearDownAll(() {
    if (!record) return;
    _fixture.parent.createSync(recursive: true);
    _fixture.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(recorded)}\n',
    );
  });

  test('every pinned row has a test and every test a pin', () {
    if (record) return;
    expect(_rows.keys.toSet(), expected.keys.toSet());
  });

  for (final MapEntry(key: id, value: steps) in _rows.entries) {
    test(id, () async {
      final server = await _Server.start();
      addTearDown(server.stop);
      final replies = await server.run(steps);
      final reply = <String, Object?>{
        'replies': replies,
        if (id.startsWith('seen.')) 'pairedSeen': await server.pairedSeen(),
      };
      if (record) {
        recorded[id] = reply;
        return;
      }
      expect(reply, expected[id]);
    });
  }
}
