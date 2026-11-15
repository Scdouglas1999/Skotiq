import 'package:skotiq_core/models.dart';

import 'validation.dart';

/// Whether the caller of a GoTo route accepted moving with the guider not
/// answering.
bool guiderSilentOk(Map<String, dynamic> payload) =>
    optionalBool(payload, GuiderForMove.silentOkKey) ?? false;

/// Runs a mount [move] ("GoTo", "park", "home") an API caller asked for and
/// returns what its answer says about the guider ([GuiderForMove]): the
/// `guider` field, and a `notice` when the move went ahead with the guider
/// silent. A GoTo refused because the guider does not answer is a 409 with
/// the code `guider_not_answering`.
Future<Map<String, Object>> mountMoveFields(
  String move,
  Future<GuiderForMove> Function() run,
) async {
  final GuiderForMove guider;
  try {
    guider = await run();
  } on GuiderNotAnsweringException catch (e) {
    throw HandlerFailure(
      code: GuiderNotAnsweringException.code,
      statusCode: 409,
      message:
          '${GuiderNotAnsweringException.message} Send '
          '"${GuiderForMove.silentOkKey}": true to move anyway.',
      details: {if (e.reason != null) 'reason': e.reason},
    );
  }
  final notice = guider.noticeFor(move);
  return {
    GuiderForMove.responseKey: guider.wire,
    if (notice != null) 'notice': notice,
  };
}
