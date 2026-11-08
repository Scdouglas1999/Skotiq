import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/runtime_mirror/channels/notice_acks_channel.dart';
import 'package:skotiq_core/src/providers/runtime_mirror/runtime_mirror_channel.dart';
import 'package:skotiq_core/src/providers/runtime_mirror/runtime_mirror_channels.dart';

// Hiding the run-warnings banner, or dismissing a tip, is one value both ends
// of a link hold. It was each window's own: hiding "4 run warnings" on the
// host left it on every linked client, including one that connected later.
void main() {
  const channel = NoticeAcknowledgmentsChannel();
  final run = DateTime.utc(2026, 11, 8, 2, 35, 30);
  const warnings = [
    'The end condition on "Heart" was already met',
    'Start guiding: Failed to start guiding',
  ];

  test('is a two-way channel in the shared list', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channels = container.read(runtimeMirrorChannelsProvider);
    final found = runtimeChannelFor(channels, 'noticeAcks');
    expect(found, isA<NoticeAcknowledgmentsChannel>());
    expect(found!.clientReports, isTrue);
  });

  test('round-trips through JSON', () {
    final value = const NoticeAcknowledgments()
        .hidingRunWarnings(run, warnings)
        .dismissingTip(depthLockHintTipId);
    final wire =
        jsonDecode(jsonEncode(channel.encode(value))) as Map<String, dynamic>;
    expect(channel.decode(wire), value);
    expect(channel.decode(null), const NoticeAcknowledgments());
  });

  test('a hidden list stays hidden until a warning is added', () {
    final ack = RunWarningsAck.of(run, warnings);
    expect(ack.covers(run, warnings), isTrue);
    expect(ack.covers(run, [...warnings, 'Centering missed']), isFalse);
    // The same texts in a later run are that run's to show.
    expect(ack.covers(run.add(const Duration(hours: 1)), warnings), isFalse);
    expect(ack.covers(run, warnings.reversed.toList()), isFalse);
  });

  test('the fingerprint is the same in every process', () {
    // FNV-1a, not String.hashCode: two apps must agree on it.
    expect(warningsFingerprint(const ['a']), 0x2b24d044);
    expect(
      warningsFingerprint(const ['ab', 'c']),
      isNot(warningsFingerprint(const ['a', 'bc'])),
    );
    expect(warningsFingerprint(const []), 0x811c9dc5);
  });

  test('a received value is written to the provider both screens read', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final value = const NoticeAcknowledgments().dismissingTip(
      depthLockHintTipId,
    );
    channel.apply(RuntimeApplyContext(container), channel.encode(value));
    expect(container.read(noticeAcknowledgmentsProvider), value);
  });
}
