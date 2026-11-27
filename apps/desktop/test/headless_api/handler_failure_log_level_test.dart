import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';

/// A handler's refusal (a 4xx the caller can act on, such as a run a manual
/// action holds) is logged as a warning; only a 5xx is an error in the log.
void main() {
  Future<({List<String> errors, List<String> warnings})> logged(
    HandlerFailure failure,
  ) async {
    final errors = <String>[];
    final warnings = <String>[];
    final handler = errorTranslationMiddleware(
      logError: (message, {fields}) => errors.add(message),
      logWarning: (message, {fields}) => warnings.add(message),
      requestIdFor: (_) => 'test-request-id',
    )((_) => throw failure);
    await handler(Request('POST', Uri.parse('http://localhost/api/x')));
    return (errors: errors, warnings: warnings);
  }

  test('a 409 refusal is a warning, not an error', () async {
    final log = await logged(
      HandlerFailure(
        code: 'run_held_by_action',
        message: 'Cannot resume: a manual action holds the run paused.',
        statusCode: 409,
        cause: StateError('refused'),
      ),
    );
    expect(log.errors, isEmpty);
    expect(log.warnings, hasLength(1));
    expect(log.warnings.single, contains('run_held_by_action'));
  });

  test('a 5xx handler failure is an error', () async {
    final log = await logged(
      HandlerFailure(
        code: 'sequencer_state_unreadable',
        message: 'The sequencer state could not be read.',
        statusCode: 503,
      ),
    );
    expect(log.warnings, isEmpty);
    expect(log.errors, hasLength(1));
  });
}
