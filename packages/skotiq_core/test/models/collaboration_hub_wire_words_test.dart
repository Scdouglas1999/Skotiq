import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

/// The collaboration words the hub understands, as its test writes them to
/// `test_fixtures/wire_words/hub_collaboration.json`.
final Map<String, Set<String>> _hub = {
  for (final MapEntry(:key, :value)
      in (jsonDecode(
                File(
                  '../../test_fixtures/wire_words/hub_collaboration.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>)
          .entries)
    key: (value as List).cast<String>().toSet(),
};

void main() {
  test('every action a client grants is one the hub resolves', () {
    final client = {for (final a in CollaborativeAction.values) a.wireName};
    expect(client.difference(_hub['actions']!), isEmpty);
  });

  test('the client licenses are the hub licenses', () {
    expect({
      for (final l in ContributionLicense.values) l.wireName,
    }, _hub['licenses']);
  });

  test('the client roles are the hub roles', () {
    expect({
      for (final r in CollaborativeRole.values) r.wireName,
    }, _hub['roles']);
  });
}
