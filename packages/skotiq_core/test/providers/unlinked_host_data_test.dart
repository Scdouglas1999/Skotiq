// A client that is not linked to its imaging host reads none of the host's
// data from its own database. A `--remote-host` desktop's own database is a
// different rig's; a phone's holds no rig rows at all. The phone keeps the
// data it browses without a rig: targets, lists, plans, notes.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

class _PinnedBackend extends BackendNotifier {
  _PinnedBackend(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// Counts every use of a dart:io HTTP client beyond building and closing it.
class _CountingHttpClient implements HttpClient {
  static int uses = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter || invocation.memberName == #close) return null;
    uses++;
    return super.noSuchMethod(invocation);
  }
}

class _NoSockets extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _CountingHttpClient();
}

Future<ProviderContainer> _process(
  LaunchRole role,
  SkotiqBackend backend,
) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await db
      .into(db.targets)
      .insert(TargetsCompanion.insert(name: 'M31', ra: 0.7, dec: 41.3));
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      launchRoleProvider.overrideWithValue(role),
      backendProvider.overrideWith((ref) => _PinnedBackend(ref, backend)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<List<String>> _targets(ProviderContainer c) async => [
  for (final t in await c.read(targetLibraryProvider).getAllTargets()) t.name,
];

Future<void> _sessions(ProviderContainer c) =>
    c.read(sessionHistoryProvider).watchAllSessions().first;

void main() {
  setUp(() => _CountingHttpClient.uses = 0);

  test('a --remote-host desktop before its link reads none of its own rows '
      'as the host\'s', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final c = await _process(LaunchRole.linkedClient, DisconnectedBackend());
      await expectLater(_targets(c), throwsA(isA<HostNotLinkedException>()));
      await expectLater(_sessions(c), throwsA(isA<HostNotLinkedException>()));
      expect(c.read(remoteHostProvider), isNull);
    }, _NoSockets());
    expect(_CountingHttpClient.uses, 0, reason: 'a refusal opens no socket');
  });

  test('a phone not linked keeps its targets and refuses rig rows', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final c = await _process(LaunchRole.mobile, DisconnectedBackend());
      expect(await _targets(c), ['M31']);
      await expectLater(_sessions(c), throwsA(isA<HostNotLinkedException>()));
    }, _NoSockets());
    expect(_CountingHttpClient.uses, 0);
  });

  test('the demo rig reads the phone\'s own rows', () async {
    final c = await _process(
      LaunchRole.mobile,
      DemoBackend(latitudeDeg: 40, longitudeDeg: -75),
    );
    expect(await _targets(c), ['M31']);
    expect(await c.read(sessionHistoryProvider).watchAllSessions().first, []);
  });

  test('a host window before its backend starts reads its own rows', () async {
    final c = await _process(LaunchRole.hostGui, DisconnectedBackend());
    expect(await _targets(c), ['M31']);
    expect(await c.read(sessionHistoryProvider).watchAllSessions().first, []);
  });
}
