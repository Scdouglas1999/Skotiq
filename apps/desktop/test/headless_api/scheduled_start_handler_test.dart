// Start at dark is held on the imaging host: a client arms, reads and cancels
// the host's schedule through these endpoints, and the host's scheduledStart
// runtime channel tells clients what it will do.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';

import 'handler_test_helpers.dart';

/// The host's night actions: arming schedules a start at [dark] on this host's
/// own armed-start timer, unless [refuse] is set.
class _HostNightActions implements NightActionApi {
  _HostNightActions(this._ref, {required this.dark, this.refuse});

  final Ref _ref;
  final DateTime dark;
  final NightText? refuse;
  ManualActionState _state = ManualActionState.idle;
  int starts = 0;

  @override
  ManualActionState get state => _state;

  @override
  DateTime? get armedStartAt => _ref.read(nightArmedStartProvider);

  @override
  Future<void> armStartAtDark() async {
    if (refuse != null) {
      _state = ManualActionState(phase: ManualActionPhase.idle, error: refuse);
      return;
    }
    _ref.read(nightArmedStartProvider.notifier).arm(dark, () async => starts++);
  }

  @override
  void cancelArmedStart() =>
      _ref.read(nightArmedStartProvider.notifier).disarm();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final dark = DateTime.now().toUtc().add(const Duration(hours: 2));

  ({ProviderContainer container, SequencerHandlers handlers}) setUpHost({
    NightText? refuse,
  }) {
    final container = createHeadlessTestContainer(
      overrides: [
        nightActionApiProvider.overrideWith(
          (ref) => _HostNightActions(ref, dark: dark, refuse: refuse),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, handlers: SequencerHandlers(container));
  }

  Request req(String method, String path) =>
      Request(method, Uri.parse('http://localhost$path'), body: '{}');

  test(
    'arming schedules the start on the host, readable and cancelable',
    () async {
      final host = setUpHost();

      final armed = await translateHandlerErrors(
        host.handlers.handleArmScheduledStart(
          req('POST', '/api/night/scheduled-start'),
        ),
      );
      expect(armed.statusCode, 200);
      final at = jsonDecode(await armed.readAsString())['at'] as String;
      expect(DateTime.parse(at), dark);
      expect(host.container.read(nightArmedStartProvider), dark);
      const channel = ScheduledStartChannel();
      expect(channel.encodeCurrent(host.container), {'at': at});

      final read = await host.handlers.handleGetScheduledStart(
        req('GET', '/api/night/scheduled-start'),
      );
      expect(jsonDecode(await read.readAsString())['at'], at);

      final canceled = await translateHandlerErrors(
        host.handlers.handleCancelScheduledStart(
          req('POST', '/api/night/scheduled-start/cancel'),
        ),
      );
      expect(canceled.statusCode, 200);
      expect(host.container.read(nightArmedStartProvider), isNull);
      expect(channel.encodeCurrent(host.container), isNull);
    },
  );

  test('a refusal comes back as 409 with the reason in words', () async {
    final host = setUpHost(refuse: const NightText('nightActErrArmNoPlan'));
    final response = await translateHandlerErrors(
      host.handlers.handleArmScheduledStart(
        req('POST', '/api/night/scheduled-start'),
      ),
    );
    expect(response.statusCode, 409);
    expect(
      jsonDecode(await response.readAsString())['message'],
      'Load a plan before arming Start at dark',
    );
    expect(host.container.read(nightArmedStartProvider), isNull);
  });
}
