/// Injectable boundary over the five Darkroom FFI entry points
/// (`apiDarkroomValidate`, `apiDarkroomRenderPreview`, `apiDarkroomRenderExport`,
/// `apiDarkroomRegistry`, `apiDarkroomCancel`).
///
/// **Why this exists.** Those entry points are free functions on the generated
/// bridge that take JSON and return JSON. Calling them straight from the dawn
/// autopilot would make the autopilot's decisions — which steps enter the first
/// draft, when a background fit is retried, what the morning report says —
/// exercisable only with the Rust dynamic library loaded. This mirrors
/// [PostSessionSeam]: the production implementation forwards to the bridge and a
/// test substitutes a scripted seam.
///
/// The boundary stays at the JSON-envelope level, so a new native knob rides
/// inside the request map and never changes this interface. The one exception is
/// the preview, which carries a pixel buffer that has no useful JSON form.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

/// The `kind` discriminator every cancelled Darkroom or post-session call
/// carries in its error payload.
///
/// Both surfaces encode the same discriminator, so one decoder recognises a
/// cancelled render and a cancelled integration run.
const String kDarkroomCancelledKind = 'cancelled';

/// One rendered preview: the RGBA buffer plus the render's own report.
///
/// `rgba` is row-major RGBA8, four bytes per pixel — the buffer
/// `AstroImageViewer` already decodes, so the editor and the autopilot share one
/// display path.
class DarkroomRenderedPreview {
  /// Width of the rendered level in pixels.
  final int width;

  /// Height of the rendered level in pixels.
  final int height;

  /// Whether the render carried colour channels.
  final bool isColor;

  /// Row-major RGBA8 samples, four bytes per pixel.
  final Uint8List rgba;

  /// The decoded render report: the level and its scale, the encoding applied,
  /// the cache accounting, and one entry per step naming what happened to it.
  final Map<String, dynamic> report;

  const DarkroomRenderedPreview({
    required this.width,
    required this.height,
    required this.isColor,
    required this.rgba,
    required this.report,
  });
}

/// A Darkroom or post-session call that stopped because cancellation was
/// requested.
///
/// The native side returns the JSON encoding of its cancelled outcome as the
/// error payload precisely so a caller reads a discriminator instead of matching
/// on prose; [tryDecode] is that reader. A message that carries no decodable
/// `{"kind":"cancelled"}` object is NOT a cancellation, and the caller must
/// treat it as the failure it is.
///
/// It is an [Exception] because the seam throws it: a cancelled call returns no
/// pixels and no paths, so there is no value for it to be.
class DarkroomCancelledOutcome implements Exception {
  /// The render id or run id that was stopped, as the native side echoed it.
  final String id;

  /// Where the call stopped. A render reports `read`, `pyramid`, `render`,
  /// `encode` or `write`; an integration run reports its pipeline stage.
  final String phase;

  /// The decoded payload in full, so a report can state everything the native
  /// side said without this class having to model each surface's extra fields.
  final Map<String, dynamic> payload;

  const DarkroomCancelledOutcome({
    required this.id,
    required this.phase,
    required this.payload,
  });

  /// Decode [error] as a cancelled outcome, or return null when it is not one.
  ///
  /// The thrown object is whatever the bridge raised — the error string itself
  /// on some paths, an exception whose `toString` embeds it on others — so the
  /// JSON object is located inside the text rather than assumed to be the whole
  /// of it. Only a payload whose `kind` is [kDarkroomCancelledKind] counts:
  /// every other JSON error payload is a genuine failure wearing the same
  /// envelope.
  static DarkroomCancelledOutcome? tryDecode(Object error) {
    final text = error is String ? error : '$error';
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      // The braces bounded prose, not JSON. That is an ordinary failure
      // message and reporting it as a cancellation would invent an operator
      // action that never happened.
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['kind'] != kDarkroomCancelledKind) return null;
    final renderId = decoded['renderId'];
    final runId = decoded['runId'];
    final phase = decoded['phase'] ?? decoded['stage'];
    return DarkroomCancelledOutcome(
      id: renderId is String
          ? renderId
          : runId is String
          ? runId
          : '',
      phase: phase is String ? phase : 'unknown',
      payload: decoded,
    );
  }

  @override
  String toString() =>
      'DarkroomCancelledOutcome(id=$id, stopped during $phase)';
}

/// A Darkroom native call failed for a reason that is not cancellation.
///
/// The bridge raises an untyped error carrying the engine's message; this wraps
/// it with the call that produced it so a job report names both.
class DarkroomSeamException implements Exception {
  /// The entry point that failed, e.g. `renderPreview`.
  final String call;

  /// The engine's own message.
  final String message;

  /// The object the bridge raised.
  final Object cause;

  const DarkroomSeamException(this.call, this.message, this.cause);

  @override
  String toString() => 'Darkroom $call failed: $message';
}

/// The Darkroom entry points the dawn autopilot and the editor call.
abstract class DarkroomSeam {
  /// Check a recipe without touching pixels.
  ///
  /// [recipeJson] is a recipe; [context] is the context map (`masterPath` is
  /// optional here and adds the base master's geometry to the reply).
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  });

  /// Render [recipeJson] over a master at one pyramid level.
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  });

  /// Write one stage of [recipeJson] at full resolution.
  Future<Map<String, dynamic>> renderExport({
    required String recipeJson,
    required Map<String, dynamic> args,
  });

  /// The operation catalogue, and — with a `masterPath` — the first-draft
  /// parameters measured from that master.
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args);

  /// Set, read, or drop the cancellation flag for a render id.
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args);
}

/// The production seam: forwards to the generated bridge.
class BridgeDarkroomSeam implements DarkroomSeam {
  const BridgeDarkroomSeam();

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    return _guard('validate', () async {
      final out = await bridge.apiDarkroomValidate(
        recipeJson: recipeJson,
        contextJson: jsonEncode(context),
      );
      return _decodeObject('validate', out);
    });
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    return _guard('renderPreview', () async {
      final preview = await bridge.apiDarkroomRenderPreview(
        recipeJson: recipeJson,
        contextJson: jsonEncode(context),
      );
      return DarkroomRenderedPreview(
        width: preview.width,
        height: preview.height,
        isColor: preview.isColor,
        rgba: preview.rgba,
        report: _decodeObject('renderPreview', preview.reportJson),
      );
    });
  }

  @override
  Future<Map<String, dynamic>> renderExport({
    required String recipeJson,
    required Map<String, dynamic> args,
  }) async {
    return _guard('renderExport', () async {
      final out = await bridge.apiDarkroomRenderExport(
        recipeJson: recipeJson,
        argsJson: jsonEncode(args),
      );
      return _decodeObject('renderExport', out);
    });
  }

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    return _guard('registry', () async {
      final out = await bridge.apiDarkroomRegistry(argsJson: jsonEncode(args));
      return _decodeObject('registry', out);
    });
  }

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async {
    return _guard('cancel', () async {
      final out = await bridge.apiDarkroomCancel(argsJson: jsonEncode(args));
      return _decodeObject('cancel', out);
    });
  }

  /// Run [body], letting a cancellation through untouched and wrapping every
  /// other bridge error in a [DarkroomSeamException] that names the call.
  ///
  /// A cancellation stays a [DarkroomCancelledOutcome] rather than becoming a
  /// failure, because the two mean opposite things to the job that asked: one
  /// is the operator's own instruction being obeyed, the other is work that
  /// could not be done.
  static Future<T> _guard<T>(String call, Future<T> Function() body) async {
    try {
      return await body();
    } on DarkroomSeamException {
      rethrow;
    } catch (error) {
      final cancelled = DarkroomCancelledOutcome.tryDecode(error);
      if (cancelled != null) throw cancelled;
      throw DarkroomSeamException(call, '$error', error);
    }
  }

  static Map<String, dynamic> _decodeObject(String call, String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      throw DarkroomSeamException(
        call,
        'the reply is not JSON: ${error.message}',
        error,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw DarkroomSeamException(
        call,
        'the reply is a ${decoded.runtimeType}, and this call answers with a '
        'JSON object',
        raw,
      );
    }
    return decoded;
  }
}
