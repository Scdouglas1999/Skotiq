// The constellation client's parsers read the replies the hub itself writes:
// test_fixtures/hub_replies/*.json come from server/skotiq_hub's
// reply_fixtures_test, so a key the hub renames fails here instead of
// decoding as a default (a contribution read as refused, a hub read as
// closed to raw frames).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

Map<String, dynamic> _reply(String name) =>
    jsonDecode(
          File('../../test_fixtures/hub_replies/$name.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

void main() {
  test('hub info', () {
    final info = HubInfo.fromJson(_reply('info'));
    expect(info.name, isNotEmpty);
    expect(info.fingerprint, hasLength(64));
    expect(info.version, isNotEmpty);
    expect(info.healpixOrder, 9);
    expect(info.tilePixels, 8);
    expect(info.acceptsRawSubs, isTrue);
    expect(info.requiresConsent, isTrue);
    expect(info.supportedLicenses, contains('cc-by'));
  });

  test('a new account', () {
    final account = HubAccount.fromJson(_reply('account'));
    expect(account.accountId, isNotEmpty);
    expect(account.bearerToken, isNotEmpty);
    expect(account.trust, greaterThan(0));
  });

  test('a contribution receipt', () {
    final receipt = ContributionReceipt.fromJson(_reply('contribution'));
    expect(receipt.contributionId, isNotEmpty);
    expect(receipt.accepted, isTrue);
    expect(receipt.trustApplied, 1.0);
    expect(receipt.totalFramesAfter, 4);
    expect(receipt.integrationSecondsAfter, 1200.0);
  });

  test('a retraction receipt', () {
    final receipt = RetractionReceipt.fromJson(_reply('retraction'));
    expect(receipt.retracted, isTrue);
    expect(receipt.totalFramesAfter, 4);
  });

  test('a raw frame receipt', () {
    final receipt = SubframeReceipt.fromJson(_reply('subframe'));
    expect(receipt.contributionId, isNotEmpty);
    expect(receipt.accepted, isTrue);
    expect(receipt.storedBytes, 80);
  });
}
