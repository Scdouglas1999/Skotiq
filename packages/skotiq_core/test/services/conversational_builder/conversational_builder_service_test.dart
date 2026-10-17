// ConversationalBuilderService tests.
//
// Uses an in-process [_FakeLlmProvider] that yields canned replies in
// sequence so we can exercise:
//   * Happy path: valid JSON on the first round.
//   * Self-correction: invalid JSON → valid JSON on round 2.
//   * Give-up: invalid for every round inside the budget.
//   * Refine: a prior result is threaded into the next user prompt.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('extractJsonObject', () {
    test('strips ```json fences and returns the JSON body', () {
      const raw = 'Here you go:\n```json\n{"a": 1}\n```';
      expect(extractJsonObject(raw).trim(), '{"a": 1}');
    });

    test('finds a balanced JSON object embedded in prose', () {
      const raw = 'sure, {"a": {"b": 2}} cheers';
      expect(extractJsonObject(raw), '{"a": {"b": 2}}');
    });

    test('handles escaped quotes inside strings', () {
      const raw = '{"a": "hi \\"there\\"", "b": 1}';
      expect(extractJsonObject(raw), raw);
    });

    test('throws on unbalanced braces', () {
      expect(
        () => extractJsonObject('{"a": 1'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when no object is present', () {
      expect(
        () => extractJsonObject('no json here'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ConversationalBuilderService', () {
    late EquipmentProfileModel profile;

    setUp(() {
      profile = const EquipmentProfileModel(
        id: 1,
        name: 'Test Rig',
        focalLength: 400,
        aperture: 80,
        focalRatio: 5.0,
        defaultGain: 100,
        defaultOffset: 50,
        defaultCoolingTemp: -10,
        filterNames: ['Ha', 'OIII'],
      );
    });

    test('happy path — valid sequence on round 1', () async {
      final provider = _FakeLlmProvider(replies: [_stockValidSequence]);
      final service = ConversationalBuilderService(
        provider: provider,
        fileService: SequenceFileService(),
      );
      final ctx = ConversationalBuilderContext(profile: profile);
      final result = await service.buildSequenceFromPrompt(
        userPrompt: 'Image the Heart Nebula for 2 hours',
        context: ctx,
      );
      expect(result.isValid, isTrue);
      expect(result.sequence, isNotNull);
      expect(result.rounds, 1);
      expect(result.rawReplies.length, 1);
      expect(result.sequence!.name, 'Heart 2h');
    });

    test(
      'self-correction — invalid JSON on round 1, valid on round 2',
      () async {
        final provider = _FakeLlmProvider(
          replies: ['Sorry, no JSON for you.', _stockValidSequence],
        );
        final service = ConversationalBuilderService(
          provider: provider,
          fileService: SequenceFileService(),
          maxSelfCorrection: 3,
        );
        final result = await service.buildSequenceFromPrompt(
          userPrompt: 'Image the Heart Nebula for 2 hours',
          context: ConversationalBuilderContext(profile: profile),
        );
        expect(result.isValid, isTrue);
        expect(result.rounds, 2);
        expect(result.rawReplies.length, 2);
        // Correction prompt should reference the round-1 reply.
        expect(provider.userPromptsSeen.length, 2);
        expect(provider.userPromptsSeen[1], contains('Your previous reply'));
      },
    );

    test(
      'gives up after maxSelfCorrection rounds and surfaces issues',
      () async {
        final provider = _FakeLlmProvider(
          replies: [
            'no json',
            'still no json',
            'still no json',
            'still no json',
          ],
        );
        final service = ConversationalBuilderService(
          provider: provider,
          fileService: SequenceFileService(),
          maxSelfCorrection: 3,
        );
        final result = await service.buildSequenceFromPrompt(
          userPrompt: 'plan something',
          context: ConversationalBuilderContext(profile: profile),
        );
        expect(result.isValid, isFalse);
        expect(result.sequence, isNull);
        expect(result.rounds, 4); // initial + 3 corrections
        expect(
          result.validationIssues.first.severity,
          ValidationSeverity.error,
        );
      },
    );

    test('throws when prompt is empty', () async {
      final service = ConversationalBuilderService(
        provider: _FakeLlmProvider(replies: ['x']),
        fileService: SequenceFileService(),
      );
      expect(
        () => service.buildSequenceFromPrompt(
          userPrompt: '   ',
          context: ConversationalBuilderContext(profile: profile),
        ),
        throwsA(isA<ConversationalBuilderException>()),
      );
    });

    test('throws when provider is unconfigured', () async {
      final provider = _FakeLlmProvider(replies: ['x'], isConfigured: false);
      final service = ConversationalBuilderService(
        provider: provider,
        fileService: SequenceFileService(),
      );
      expect(
        () => service.buildSequenceFromPrompt(
          userPrompt: 'do a thing',
          context: ConversationalBuilderContext(profile: profile),
        ),
        throwsA(isA<ConversationalBuilderUnconfigured>()),
      );
    });

    test('refine preserves prior context and amends the user prompt', () async {
      final firstProvider = _FakeLlmProvider(replies: [_stockValidSequence]);
      final firstService = ConversationalBuilderService(
        provider: firstProvider,
        fileService: SequenceFileService(),
      );
      final first = await firstService.buildSequenceFromPrompt(
        userPrompt: 'initial',
        context: ConversationalBuilderContext(profile: profile),
      );
      expect(first.isValid, isTrue);

      final refineProvider = _FakeLlmProvider(replies: [_stockValidSequence]);
      final refineService = ConversationalBuilderService(
        provider: refineProvider,
        fileService: SequenceFileService(),
      );
      final refined = await refineService.buildSequenceFromPrompt(
        userPrompt: 'use 300s subs instead',
        context: ConversationalBuilderContext(
          profile: profile,
          refineFrom: first,
        ),
      );
      expect(refined.isValid, isTrue);
      final firstUserPrompt = refineProvider.userPromptsSeen.single;
      expect(
        firstUserPrompt,
        contains('You previously produced this sequence'),
      );
      expect(firstUserPrompt, contains('use 300s subs instead'));
    });

    test(
      'wire-level provider error surfaces as ConversationalBuilderException',
      () async {
        final provider = _FakeLlmProvider.throwing(
          const LlmProviderException(
            providerName: 'test',
            statusCode: 401,
            message: 'unauthorized',
          ),
        );
        final service = ConversationalBuilderService(
          provider: provider,
          fileService: SequenceFileService(),
        );
        expect(
          () => service.buildSequenceFromPrompt(
            userPrompt: 'plan',
            context: ConversationalBuilderContext(profile: profile),
          ),
          throwsA(isA<ConversationalBuilderException>()),
        );
      },
    );
  });

  group('SystemPromptBuilder', () {
    test('includes equipment profile, location, and node schema', () {
      const profile = EquipmentProfileModel(
        id: 1,
        name: 'Mono Rig',
        focalLength: 400,
        aperture: 80,
        focalRatio: 5.0,
        filterNames: ['L', 'R', 'G', 'B', 'Ha'],
      );
      const builder = SystemPromptBuilder();
      final prompt = builder.build(
        const ConversationalBuilderContext(
          profile: profile,
          latitudeDeg: 41.2,
          longitudeDeg: -74.0,
          weatherNote: 'Clear skies, no clouds',
          options: ConversationalBuilderOptions(maxSessionHours: 4),
        ),
      );
      expect(prompt, contains('Mono Rig'));
      expect(prompt, contains('41.200'));
      expect(prompt, contains('Clear skies'));
      expect(prompt, contains('SmartExposure'));
      expect(prompt, contains('TargetScheduler'));
      expect(prompt, contains('Output'));
      // Few-shot examples must be present.
      expect(prompt, contains('Example A'));
      expect(prompt, contains('Heart Nebula'));
    });
  });
}

/// Stock valid sequence JSON used by multiple tests. Compact form of
/// the system-prompt's Example A.
const String _stockValidSequence = '''
{
  "schemaVersion": 1,
  "name": "Heart 2h",
  "description": "Test sequence",
  "rootNodeId": "root",
  "nodes": {
    "root": {"id": "root", "nodeType": "InstructionSet", "name": "Root",
      "parentId": null, "childIds": ["tgt"], "orderIndex": 0,
      "isEnabled": true},
    "tgt": {"id": "tgt", "nodeType": "TargetHeader", "name": "Heart",
      "parentId": "root", "childIds": ["exp"], "orderIndex": 0,
      "isEnabled": true,
      "targetName": "Heart Nebula", "raHours": 2.55, "decDegrees": 61.45},
    "exp": {"id": "exp", "nodeType": "Exposure", "name": "Ha",
      "parentId": "tgt", "childIds": [], "orderIndex": 0,
      "isEnabled": true,
      "durationSecs": 300, "count": 24, "frameType": "light",
      "filter": "Ha", "binning": "one"}
  }
}
''';

/// In-process LlmProvider that returns canned replies in sequence and
/// records the user prompts it saw so tests can assert against the
/// self-correction prompt shape.
class _FakeLlmProvider implements LlmProvider {
  final List<String> replies;
  final LlmProviderException? throwError;
  final List<String> userPromptsSeen = [];
  final List<String> systemPromptsSeen = [];
  final bool _configured;
  int _next = 0;

  _FakeLlmProvider({required this.replies, bool isConfigured = true})
    : throwError = null,
      _configured = isConfigured;

  _FakeLlmProvider.throwing(LlmProviderException error)
    : replies = const [],
      throwError = error,
      _configured = true;

  @override
  String get name => 'Fake';

  @override
  LlmProviderKind get kind => LlmProviderKind.openAiCompatible;

  @override
  bool get isConfigured => _configured;

  @override
  Future<LlmResponse> generate({
    required String systemPrompt,
    required String userPrompt,
  }) async {
    systemPromptsSeen.add(systemPrompt);
    userPromptsSeen.add(userPrompt);
    if (throwError != null) throw throwError!;
    if (_next >= replies.length) {
      throw StateError('Fake provider exhausted its canned replies.');
    }
    final reply = replies[_next++];
    return LlmResponse(text: reply);
  }

  @override
  Future<LlmConnectionTestResult> testConnection() async {
    return const LlmConnectionTestResult(
      success: true,
      message: 'fake ok',
      roundTripMs: 1,
    );
  }

  @override
  void close() {}
}
