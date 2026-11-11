import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/wire.dart';

void main() {
  group('ApiErrorBody', () {
    test('writes each layout as the host has always written it', () {
      expect(
        const ApiErrorBody(
          code: 'goal_not_found',
          message: 'No such goal',
          layout: ApiErrorLayout.codeAsError,
          requestId: 'r1',
          details: {'goalId': 'm42'},
        ).toJson(),
        {
          'error': 'goal_not_found',
          'code': 'goal_not_found',
          'message': 'No such goal',
          'requestId': 'r1',
          'goalId': 'm42',
        },
      );
      expect(
        const ApiErrorBody(
          code: 'handler_timeout',
          message: 'Too slow',
          details: {'error': 'overridden', 'budget': 60},
        ).toJson(),
        {
          'error': 'Too slow',
          'budget': 60,
          'code': 'handler_timeout',
          'message': 'Too slow',
        },
      );
    });

    test('reads a coded body and a prose body, and leaves the rest', () {
      final coded = ApiErrorBody.tryParse({
        'error': 'Too slow',
        'code': 'handler_timeout',
        'message': 'Too slow',
      }, httpStatus: 503)!;
      expect(coded.code, 'handler_timeout');
      expect(coded.message, 'Too slow');

      final prose = ApiErrorBody.tryParse({
        'error': 'Device not found',
      }, httpStatus: 404)!;
      expect(prose.code, 'not_found');
      expect(prose.message, 'Device not found');
      expect(prose.layout, ApiErrorLayout.prose);

      // `{error: <category>, message}` has no code; the caller decides.
      expect(
        ApiErrorBody.tryParse({'error': 'Access denied', 'message': 'No'}),
        isNull,
      );
      expect(ApiErrorBody.tryParse({'status': 'ok'}), isNull);
    });
  });

  group('sequence library rows', () {
    final summary = SequenceSummaryDto(
      id: 3,
      name: 'M31 LRGB',
      nodeCount: 12,
      targetCount: 1,
      exposureCount: 40,
      totalIntegrationSecs: 7200,
      runCount: 2,
      lastRunAt: DateTime.utc(2026, 11, 2, 3),
      tags: const ['galaxy'],
      isFavorite: true,
      createdAt: DateTime.utc(2026, 10, 1),
      modifiedAt: DateTime.utc(2026, 11, 1),
    );

    test('what the host writes is what a client reads', () {
      final read = SequenceSummaryDto.fromJson(summary.toJson());
      expect(read.toJson(), summary.toJson());
      expect(summary.toJson().keys, [
        'id',
        'name',
        'nodeCount',
        'targetCount',
        'exposureCount',
        'totalIntegrationSecs',
        'primaryTargetName',
        'lastRunAt',
        'runCount',
        'tags',
        'isFavorite',
        'createdAt',
        'modifiedAt',
      ]);

      final version = SequenceVersionDto(
        id: 9,
        sequenceId: 3,
        snapshotJson: '{}',
        createdAt: DateTime.utc(2026, 11, 1),
      );
      expect(
        SequenceVersionDto.fromJson(version.toJson()).toJson(),
        version.toJson(),
      );
      expect(
        SequenceVersionSummaryDto.fromJson(version.toJson()).label,
        isNull,
      );
    });

    test('a row that contradicts itself is refused', () {
      final json = summary.toJson()..['lastRunAt'] = null;
      expect(() => SequenceSummaryDto.fromJson(json), throwsFormatException);
    });
  });
}
