import 'package:skotiq_core/errors.dart' show userFacingError;


/// The body for the First Light error empty-state: a sentence a person can act
/// on, then the raw detail.
///
/// A raw error object — "FormatException: Invalid radix-10 number (at
/// character 1)", caret diagram and all — tells an operator nothing about
/// whether their night's data is gone. The technical text is still shown
/// because support needs it, but it is not the whole message.
String firstLightErrorBody(Object error) {
  return 'Skotiq could not read the candidate list. Your frames and any '
      'detections already found are untouched — this is a read problem, not '
      'lost data. Retry re-runs the query.\n\n'
      'Details: ${userFacingError(error)}';
}
