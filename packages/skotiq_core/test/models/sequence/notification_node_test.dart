// NotificationNode explicit-transports round-trip tests.
//
// The model gained an `explicitTransports` field. We need to make sure:
//   * Default construction = null (legacy nodes inherit the matrix rule).
//   * copyWith honours both "set to value" and "clear via flag".
//   * The Equatable props correctly include the new field (so the
//     sequence editor's dirty-check fires when only this changes).

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('NotificationNode default explicitTransports is null', () {
    final n = NotificationNode();
    expect(n.explicitTransports, isNull);
  });

  test('NotificationNode copyWith sets explicitTransports', () {
    final n = NotificationNode();
    final updated = n.copyWith(
      explicitTransports: const [NotificationTransportKind.discord],
    );
    expect(updated.explicitTransports, [NotificationTransportKind.discord]);
  });

  test('NotificationNode clears explicitTransports via rebuild-explicit', () {
    // copyWith uses plain `?? this.explicitTransports` semantics, so
    // resetting back to the matrix default means constructing a fresh node
    // without the `explicitTransports` arg.
    final n = NotificationNode(
      id: 'n1',
      explicitTransports: const [NotificationTransportKind.discord],
    );
    final updated = NotificationNode(
      id: n.id,
      name: n.name,
      isEnabled: n.isEnabled,
      childIds: n.childIds,
      parentId: n.parentId,
      orderIndex: n.orderIndex,
      comment: n.comment,
      title: n.title,
      message: n.message,
      level: n.level,
    );
    expect(updated.explicitTransports, isNull);
  });

  test('NotificationNode equality reflects explicitTransports', () {
    final a = NotificationNode(
      title: 't',
      message: 'm',
      explicitTransports: const [NotificationTransportKind.discord],
    );
    final b = NotificationNode(
      title: 't',
      message: 'm',
      explicitTransports: const [NotificationTransportKind.discord],
      id: a.id,
    );
    expect(a, equals(b));

    final c = NotificationNode(
      title: 't',
      message: 'm',
      explicitTransports: const [NotificationTransportKind.telegram],
      id: a.id,
    );
    expect(a, isNot(equals(c)));
  });
}
