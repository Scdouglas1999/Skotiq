// The morning message is gated by the operator's own event flags, and the job
// records which flag decided.
//
// The failure this guards against is the opposite of a missing notification: a
// pipeline that notices the gate is closed and reroutes through an ungated
// event family so the message arrives anyway. That silently overrides a switch
// the operator set, and the report would still say the message was sent.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/notification_service.dart';

DawnJobReport _report() => DawnJobReport(
  jobId: 1,
  kind: 'dawn',
  sessionId: 7,
  startedAt: DateTime.utc(2026, 8, 16, 4),
  finishedAt: DateTime.utc(2026, 8, 16, 5),
  state: 'done',
  masters: const [],
  withoutFile: const [],
  delivery: null,
  deliveryProblems: const [],
  notification: null,
  failure: null,
);

/// A notifier over a service whose webhook posts are counted.
({NotificationServiceDawnNotifier notifier, int Function() posts}) _build(
  AppSettingsState? settings,
) {
  var posts = 0;
  final service = NotificationService.testing(
    settingsReader: () => settings,
    httpClient: MockClient((_) async {
      posts++;
      return http.Response('ok', 200);
    }),
    soundPlayer: () async {},
  );
  addTearDown(service.dispose);
  return (
    notifier: NotificationServiceDawnNotifier(
      notifications: service,
      settings: () => settings,
    ),
    posts: () => posts,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the master notifications switch silences the morning message',
    () async {
      final built = _build(
        const AppSettingsState(
          notificationsEnabled: false,
          notifyOnSequenceComplete: true,
        ),
      );
      final decision = await built.notifier.announce(_report());

      expect(decision.sent, isFalse);
      expect(decision.reason, contains('switched off in Settings'));
      expect(built.posts(), 0);
    },
  );

  test(
    'the Sequence Complete flag silences the morning message and is named',
    () async {
      final built = _build(
        const AppSettingsState(
          notificationsEnabled: true,
          notifyOnSequenceComplete: false,
        ),
      );
      final decision = await built.notifier.announce(_report());

      expect(decision.sent, isFalse);
      expect(decision.reason, contains('"Sequence Complete"'));
      expect(built.posts(), 0);
    },
  );

  test(
    'settings that have not loaded stop the message rather than guessing',
    () async {
      final built = _build(null);
      final decision = await built.notifier.announce(_report());

      expect(decision.sent, isFalse);
      expect(decision.reason, contains('have not loaded'));
      expect(built.posts(), 0);
    },
  );

  test('an open gate sends, and the decision names what took it', () async {
    final built = _build(
      const AppSettingsState(
        notificationsEnabled: true,
        notifyOnSequenceComplete: true,
        soundEnabled: false,
        discordWebhook: 'https://discord.com/api/webhooks/test',
      ),
    );
    final decision = await built.notifier.announce(_report());

    expect(decision.sent, isTrue);
    expect(decision.reason, contains('webhook'));
    expect(built.posts(), greaterThan(0));
  });

  test('a message nothing carried is not reported as sent', () async {
    // No webhook configured and no router on this service, so nothing left
    // the process. `sent` used to be hard-coded true here, and the morning
    // message is the ONLY surface that lists the night's delivery problems —
    // so a night nobody was told about read exactly like one they were.
    final built = _build(
      const AppSettingsState(
        notificationsEnabled: true,
        notifyOnSequenceComplete: true,
        soundEnabled: false,
      ),
    );
    final decision = await built.notifier.announce(_report());

    expect(decision.sent, isFalse);
    expect(decision.reason, contains('Nothing was sent'));
    expect(built.posts(), 0);
  });

  group('the deep link the tap follows', () {
    DawnMasterReport master({
      required int masterId,
      int? recipeId,
      String? draftRenderPath,
    }) => DawnMasterReport(
      master: DawnMaster(
        masterId: masterId,
        targetId: null,
        name: 'M31 Ha',
        filter: 'Ha',
        masterFitsPath: '/masters/m31_ha.fits',
        channels: 1,
        width: 4000,
        height: 3000,
        frameCount: 30,
        totalIntegrationSeconds: 9000,
      ),
      targetName: 'M31',
      stats: DawnMasterStats.unrecorded,
      draft: null,
      recipeId: recipeId,
      draftRenderPath: draftRenderPath,
      failure: null,
    );

    DawnJobReport reportWith(List<DawnMasterReport> masters) => DawnJobReport(
      jobId: 1,
      kind: 'dawn',
      sessionId: 7,
      startedAt: DateTime.utc(2026, 8, 16, 4),
      finishedAt: DateTime.utc(2026, 8, 16, 5),
      state: 'done',
      masters: masters,
      withoutFile: const [],
      delivery: null,
      deliveryProblems: const [],
      notification: null,
      failure: null,
    );

    test('names the first master that saved a recipe AND rendered it', () {
      expect(
        draftDeepLinkFor(
          reportWith([
            master(masterId: 1, recipeId: 11, draftRenderPath: '/d/1.jpg'),
            master(masterId: 2, recipeId: 12, draftRenderPath: '/d/2.jpg'),
          ]),
        ),
        'darkroom_draft:11',
      );
    });

    test('skips a recipe whose draft the engine refused to render', () {
      expect(
        draftDeepLinkFor(
          reportWith([
            master(masterId: 1, recipeId: 11, draftRenderPath: null),
            master(masterId: 2, recipeId: 12, draftRenderPath: '/d/2.jpg'),
          ]),
        ),
        'darkroom_draft:12',
        reason: 'a recipe with no draft opens onto the same refusal',
      );
    });

    test('a night with no draft carries no link at all', () {
      expect(draftDeepLinkFor(reportWith(const [])), isNull);
      expect(
        draftDeepLinkFor(
          reportWith([
            master(masterId: 1, recipeId: null, draftRenderPath: '/d/1.jpg'),
          ]),
        ),
        isNull,
        reason:
            'a draft with no saved recipe has nothing for the editor to open',
      );
    });
  });
}
