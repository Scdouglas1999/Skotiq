import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/response_helpers.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

ProviderContainer createHeadlessTestContainer({
  List<Override> overrides = const [],
}) {
  final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  return ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(database), ...overrides],
  );
}

Future<Response> translateHandlerErrors(Future<Response> response) async {
  try {
    return await response;
  } on BadRequestError catch (error) {
    return jsonBadRequest(error.toJsonBody());
  } on HandlerFailure catch (error) {
    return jsonResponse(
      error.toJsonBody(requestId: 'test-request'),
      statusCode: error.statusCode,
    );
  } catch (_) {
    return jsonInternalServerError({
      'error': 'internal_error',
      'requestId': 'test-request',
    });
  }
}
