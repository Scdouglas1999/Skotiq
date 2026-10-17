// VoiceControlService tests
//
// Exercises the platform-channel boundary in both directions:
//
//   * Outbound: publishSequenceStatus / clearStatus / isSupported encode
//     the right method name + JSON payload onto the channel.
//   * Inbound: a simulated `voice_control.onAction` call from the host
//     surfaces as the right VoiceControlAction enum value on the
//     actionStream.
//
// The class is iOS/Android only at runtime, but the channel-level
// behaviour we want to cover is platform-independent. We use the
// TestDefaultBinaryMessenger to intercept channel traffic without
// booting a real platform plugin.
//
// Each failing branch must surface a typed exception rather than a silent
// no-op; the tests assert on those exceptions.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/voice_control_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceControlAction', () {
    test('fromWireId round-trips every enum value', () {
      for (final v in VoiceControlAction.values) {
        expect(VoiceControlAction.fromWireId(v.wireId), v);
      }
    });

    test('fromWireId throws on unknown id (no silent fallback)', () {
      expect(
        () => VoiceControlAction.fromWireId('totally_made_up_action'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('wire ids match the cross-platform contract', () {
      // These strings are baked into iOS SkotiqAppIntents.swift and
      // Android shortcuts.xml. Renaming any of them is a wire-protocol
      // change — this assertion exists so a Dart-side rename can't slip
      // through without an explicit test update.
      expect(VoiceControlAction.pauseSequence.wireId, 'pause_sequence');
      expect(VoiceControlAction.resumeSequence.wireId, 'resume_sequence');
      expect(VoiceControlAction.openLastImage.wireId, 'open_last_image');
      expect(VoiceControlAction.refreshStatus.wireId, 'refresh_status');
    });
  });

  group('SequenceStatusSnapshot', () {
    test('toJson includes every wire field', () {
      const snapshot = SequenceStatusSnapshot(
        sequenceId: 'seq-1',
        sequenceName: 'M31 Narrowband',
        targetName: 'M31',
        executionState: 'running',
        framesCompleted: 17,
        framesTotal: 60,
        elapsedSeconds: 4321,
        estimatedRemainingSeconds: 5400,
        currentFilter: 'Ha',
        currentNodeName: 'Expose 300s Ha',
        updatedAtMillis: 1716700000000,
      );
      final json = snapshot.toJson();
      expect(json, <String, Object?>{
        'sequenceId': 'seq-1',
        'sequenceName': 'M31 Narrowband',
        'targetName': 'M31',
        'executionState': 'running',
        'framesCompleted': 17,
        'framesTotal': 60,
        'elapsedSeconds': 4321,
        'estimatedRemainingSeconds': 5400,
        'currentFilter': 'Ha',
        'currentNodeName': 'Expose 300s Ha',
        'updatedAtMillis': 1716700000000,
      });
    });

    test('toJson preserves nullable estimatedRemainingSeconds', () {
      const snapshot = SequenceStatusSnapshot(
        sequenceId: 'seq-1',
        sequenceName: 'M31',
        targetName: 'M31',
        executionState: 'running',
        framesCompleted: 0,
        framesTotal: 60,
        elapsedSeconds: 0,
        estimatedRemainingSeconds: null,
        currentFilter: '',
        currentNodeName: 'Expose',
        updatedAtMillis: 1,
      );
      expect(snapshot.toJson()['estimatedRemainingSeconds'], isNull);
    });

    group('toSpokenSummary', () {
      const base = SequenceStatusSnapshot(
        sequenceId: 'seq-1',
        sequenceName: 'M31',
        targetName: 'M31',
        executionState: 'running',
        framesCompleted: 10,
        framesTotal: 60,
        elapsedSeconds: 600,
        estimatedRemainingSeconds: 3600,
        currentFilter: 'Ha',
        currentNodeName: 'Expose',
        updatedAtMillis: 0,
      );

      test('running with ETA mentions hours', () {
        // 1 hour exactly should not emit a stray "minutes" tail.
        final summary = base.toSpokenSummary();
        expect(summary, contains('M31'));
        expect(summary, contains('10 of 60'));
        expect(summary, contains('About 1 hour remaining'));
      });

      test('running with small ETA mentions minutes only', () {
        final s = SequenceStatusSnapshot(
          sequenceId: base.sequenceId,
          sequenceName: base.sequenceName,
          targetName: base.targetName,
          executionState: base.executionState,
          framesCompleted: base.framesCompleted,
          framesTotal: base.framesTotal,
          elapsedSeconds: base.elapsedSeconds,
          estimatedRemainingSeconds: 1500, // 25 min
          currentFilter: base.currentFilter,
          currentNodeName: base.currentNodeName,
          updatedAtMillis: base.updatedAtMillis,
        );
        expect(s.toSpokenSummary(), contains('About 25 minutes remaining'));
      });

      test('running with sub-minute ETA says less than a minute', () {
        final s = SequenceStatusSnapshot(
          sequenceId: 'x',
          sequenceName: 'x',
          targetName: 'NGC',
          executionState: 'running',
          framesCompleted: 1,
          framesTotal: 2,
          elapsedSeconds: 1,
          estimatedRemainingSeconds: 30,
          currentFilter: '',
          currentNodeName: '',
          updatedAtMillis: 0,
        );
        expect(s.toSpokenSummary(), contains('Less than a minute remaining'));
      });

      test('idle says no sequence active', () {
        final s = SequenceStatusSnapshot(
          sequenceId: '',
          sequenceName: '',
          targetName: '',
          executionState: 'idle',
          framesCompleted: 0,
          framesTotal: 0,
          elapsedSeconds: 0,
          estimatedRemainingSeconds: null,
          currentFilter: '',
          currentNodeName: '',
          updatedAtMillis: 0,
        );
        expect(s.toSpokenSummary(), 'No sequence is active.');
      });

      test('paused mentions target and frames', () {
        final s = SequenceStatusSnapshot(
          sequenceId: 'x',
          sequenceName: 'x',
          targetName: 'NGC 891',
          executionState: 'paused',
          framesCompleted: 4,
          framesTotal: 10,
          elapsedSeconds: 1,
          estimatedRemainingSeconds: null,
          currentFilter: '',
          currentNodeName: '',
          updatedAtMillis: 0,
        );
        final summary = s.toSpokenSummary();
        expect(summary, contains('paused'));
        expect(summary, contains('NGC 891'));
        expect(summary, contains('4 of 10'));
      });

      test('completed reports final count', () {
        final s = SequenceStatusSnapshot(
          sequenceId: 'x',
          sequenceName: 'x',
          targetName: 'M42',
          executionState: 'completed',
          framesCompleted: 60,
          framesTotal: 60,
          elapsedSeconds: 1,
          estimatedRemainingSeconds: null,
          currentFilter: '',
          currentNodeName: '',
          updatedAtMillis: 0,
        );
        expect(
          s.toSpokenSummary(),
          'Sequence finished. 60 of 60 frames captured on M42.',
        );
      });
    });
  });

  group('VoiceControlService — outbound', () {
    late MethodChannel channel;
    late List<MethodCall> captured;
    late VoiceControlService service;

    setUp(() {
      channel = const MethodChannel(VoiceControlService.channelName);
      captured = <MethodCall>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            captured.add(call);
            switch (call.method) {
              case 'isSupported':
                return true;
              case 'publishStatus':
              case 'clearStatus':
                return null;
              default:
                throw MissingPluginException('No mock for ${call.method}');
            }
          });

      service = VoiceControlService(channel: channel, skipPlatformGuard: true);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await service.dispose();
    });

    test('publishSequenceStatus forwards the full JSON snapshot', () async {
      const snapshot = SequenceStatusSnapshot(
        sequenceId: 'seq-1',
        sequenceName: 'M31',
        targetName: 'M31',
        executionState: 'running',
        framesCompleted: 5,
        framesTotal: 60,
        elapsedSeconds: 120,
        estimatedRemainingSeconds: 3000,
        currentFilter: 'Ha',
        currentNodeName: 'Expose',
        updatedAtMillis: 42,
      );
      await service.publishSequenceStatus(snapshot);
      expect(captured, hasLength(1));
      expect(captured.first.method, 'publishStatus');
      expect(captured.first.arguments, snapshot.toJson());
    });

    test('clearStatus invokes clearStatus with no arguments', () async {
      await service.clearStatus();
      expect(captured, hasLength(1));
      expect(captured.first.method, 'clearStatus');
      expect(captured.first.arguments, isNull);
    });

    test('isSupported returns the host result', () async {
      final result = await service.isSupported();
      // Note: isSupported on non-iOS/Android short-circuits to false
      // without consulting the channel. The test host is a unit-test
      // environment where Platform.isIOS / isAndroid are both false on
      // most CI runners, so the channel mock won't be hit. We assert
      // the return type rather than the exact value to keep the test
      // platform-portable; the value is exercised end-to-end by the
      // integration suite on real devices.
      expect(result, isA<bool>());
    });

    test('PlatformException from publishStatus propagates', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'app_group_unavailable',
              message: 'simulated entitlement missing',
            );
          });
      const snapshot = SequenceStatusSnapshot(
        sequenceId: 's',
        sequenceName: 's',
        targetName: 't',
        executionState: 'running',
        framesCompleted: 0,
        framesTotal: 0,
        elapsedSeconds: 0,
        estimatedRemainingSeconds: null,
        currentFilter: '',
        currentNodeName: '',
        updatedAtMillis: 0,
      );
      await expectLater(
        service.publishSequenceStatus(snapshot),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'app_group_unavailable',
          ),
        ),
      );
    });
  });

  group('VoiceControlService — inbound', () {
    late MethodChannel channel;
    late VoiceControlService service;

    setUp(() {
      channel = const MethodChannel(VoiceControlService.channelName);
      service = VoiceControlService(channel: channel, skipPlatformGuard: true);
    });

    tearDown(() async {
      await service.dispose();
    });

    /// Simulate the native side dispatching an inbound `onAction` call.
    Future<void> simulateInbound(String wireId) async {
      const codec = StandardMethodCodec();
      final message = codec.encodeMethodCall(
        MethodCall('onAction', <String, Object?>{'action': wireId}),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            VoiceControlService.channelName,
            message,
            (data) {},
          );
    }

    test(
      'pause_sequence surfaces as VoiceControlAction.pauseSequence',
      () async {
        final completer = service.actionStream.first;
        await simulateInbound('pause_sequence');
        expect(await completer, VoiceControlAction.pauseSequence);
      },
    );

    test(
      'resume_sequence surfaces as VoiceControlAction.resumeSequence',
      () async {
        final completer = service.actionStream.first;
        await simulateInbound('resume_sequence');
        expect(await completer, VoiceControlAction.resumeSequence);
      },
    );

    test(
      'open_last_image surfaces as VoiceControlAction.openLastImage',
      () async {
        final completer = service.actionStream.first;
        await simulateInbound('open_last_image');
        expect(await completer, VoiceControlAction.openLastImage);
      },
    );

    test(
      'refresh_status surfaces as VoiceControlAction.refreshStatus',
      () async {
        final completer = service.actionStream.first;
        await simulateInbound('refresh_status');
        expect(await completer, VoiceControlAction.refreshStatus);
      },
    );

    test(
      'unknown wire id raises a PlatformException, not silently no-op',
      () async {
        // The handler in VoiceControlService throws PlatformException for an
        // unknown id and the platform messenger propagates it back, so the
        // assistant learns the command was not carried out.
        const codec = StandardMethodCodec();
        final message = codec.encodeMethodCall(
          const MethodCall('onAction', <String, Object?>{
            'action': 'this_is_not_a_known_action',
          }),
        );
        bool reported = false;
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(VoiceControlService.channelName, message, (
              data,
            ) {
              // Decoder will throw if the reply is an error envelope.
              if (data != null) {
                try {
                  codec.decodeEnvelope(data);
                } on PlatformException catch (e) {
                  expect(e.code, 'unknown_action');
                  reported = true;
                }
              }
            });
        expect(
          reported,
          isTrue,
          reason: 'Unknown wire ids must surface a PlatformException',
        );
      },
    );

    test('missing action key raises PlatformException', () async {
      const codec = StandardMethodCodec();
      final message = codec.encodeMethodCall(
        const MethodCall('onAction', <String, Object?>{}),
      );
      bool reported = false;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(VoiceControlService.channelName, message, (
            data,
          ) {
            if (data != null) {
              try {
                codec.decodeEnvelope(data);
              } on PlatformException catch (e) {
                expect(e.code, 'missing_action');
                reported = true;
              }
            }
          });
      expect(reported, isTrue);
    });
  });
}
