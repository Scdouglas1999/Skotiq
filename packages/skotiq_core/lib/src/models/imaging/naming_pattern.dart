import 'package:equatable/equatable.dart';
import 'package:path/path.dart' as p;

import 'imaging_models.dart';

/// The Settings file naming pattern, where its frames go, and in which format.
///
/// The pattern is a `/`-separated path relative to [baseDir], filename stem
/// included; every `$TOKEN` in it is a [NamingToken]. The same pattern names
/// manual captures, sequence frames, Flat Wizard frames and a secondary
/// camera's frames.
class NamingPattern extends Equatable {
  final String pattern;
  final String baseDir;
  final ImageFileFormat format;

  const NamingPattern({
    this.pattern = r'$TARGET/$FRAMETYPE/$TARGET_$FILTER_$EXPTIME_$FRAMENUM',
    this.baseDir = '.',
    this.format = ImageFileFormat.fits,
  });

  @override
  List<Object?> get props => [pattern, baseDir, format];

  /// What a `$TOKEN` looks like: uppercase letters only, so `_` stays a
  /// literal separator (`$TARGET_$FILTER` is two tokens).
  static final RegExp tokenSyntax = RegExp(r'\$[A-Z]+');

  /// `$FILTER` of a frame taken with no filter. The run's label
  /// (`NO_FILTER_LABEL` in the sequencer), so manual and sequence frames
  /// share one folder.
  static const String noFilterLabel = 'nofilter';

  /// `$TARGET` of a frame taken with no target: a calibration frame is filed
  /// under its frame type, a sky frame as untargeted. The run's labels
  /// (`calibration_target_label` and `NO_TARGET_LABEL` in the sequencer).
  static String noTargetLabel(FrameType frameType) => switch (frameType) {
    FrameType.dark ||
    FrameType.flat ||
    FrameType.bias ||
    FrameType.darkFlat => frameType.imageType,
    FrameType.light || FrameType.snapshot => 'untargeted',
  };

  static final RegExp _unsafeSegmentChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

  /// [value] as one filename segment. Names are data, never path syntax: a
  /// target named `M31/Ha` must not make a folder, and `..` must never
  /// leave the output folder. Pinned with the run's rule by
  /// `test_fixtures/path_segment/cases.json`.
  static String pathSegment(String value) {
    var segment = value.replaceAll(_unsafeSegmentChars, '_').trim();
    segment = segment.replaceFirst(RegExp(r'^[. _]+'), '');
    segment = segment.replaceAll(RegExp(r'[. ]+$'), '');
    if (segment.isEmpty || segment == '.' || segment == '..') return '_';
    return segment;
  }

  static final Map<String, NamingToken> _byName = {
    for (final token in NamingToken.values) token.text: token,
  };

  /// Why [pattern] cannot name a frame, in words for the operator, or null
  /// when it can.
  static String? problem(String pattern) {
    if (pattern.trim().isEmpty ||
        p.posix.isAbsolute(pattern) ||
        p.windows.isAbsolute(pattern)) {
      return 'The naming pattern must be a non-empty relative path.';
    }
    final unknown = {
      for (final m in tokenSyntax.allMatches(pattern))
        if (!_byName.containsKey(m.group(0))) m.group(0)!,
    };
    if (unknown.isNotEmpty) {
      return 'Unknown variable${unknown.length == 1 ? '' : 's'} '
          '${unknown.join(', ')}. Supported: '
          '${NamingToken.values.map((t) => t.text).join(', ')}.';
    }
    // Every value is one safe, non-empty segment, so a stand-in decides.
    final expanded = pattern.replaceAll(tokenSyntax, 'x');
    if (expanded.contains(r'$')) {
      return 'The naming pattern contains an invalid variable. Variables are '
          r'uppercase letters after a $, e.g. $TARGET.';
    }
    for (final segment in expanded.split('/')) {
      if (segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          _unsafeSegmentChars.hasMatch(segment)) {
        return 'Unsafe path segment "$segment". Segments cannot be empty, "." '
            r'or "..", and cannot contain \ < > : " | ? *.';
      }
    }
    return null;
  }

  /// The folders and filename stem [pattern] gives a frame of [values], each
  /// value made one segment. [pattern] must have no [problem].
  static List<String> segments(
    String pattern,
    Map<NamingToken, String> values,
  ) {
    assert(problem(pattern) == null, problem(pattern));
    return pattern
        .replaceAllMapped(
          tokenSyntax,
          (m) => pathSegment(values[_byName[m.group(0)]]!),
        )
        .split('/');
  }

  /// Every token's value for [frame] of [step].
  static Map<NamingToken, String> values(
    NamingStep step,
    NamingFrame frame,
  ) => {
    for (final token in NamingToken.values) token: token.valueFor(step, frame)!,
  };

  /// [pattern] as the save template of a run's frames: a per-frame token
  /// becomes the run's placeholder and every other token takes its value
  /// from [step], made one segment as a manual capture's is. [pattern] must
  /// have no [problem].
  static String runTemplate(String pattern, NamingStep step) {
    assert(problem(pattern) == null, problem(pattern));
    return pattern.replaceAllMapped(tokenSyntax, (m) {
      final token = _byName[m.group(0)]!;
      return token.runPlaceholder ??
          pathSegment(token.valueFor(step)!).replaceAll(r'${', r'$${');
    });
  }

  /// [pattern] checked, and when usable the example path it gives (with
  /// [extension]) at [now].
  static NamingPatternCheck check(
    String pattern, {
    String extension = 'fits',
    DateTime? now,
  }) {
    final error = problem(pattern);
    if (error != null) return NamingPatternCheck._(error, null);
    final at = (now ?? DateTime.now()).toUtc();
    final parts = segments(
      pattern,
      values(
        NamingStep(
          frameType: FrameType.light,
          gain: 100,
          offset: 10,
          binX: 1,
          binY: 1,
          sequence: 'M31',
          session: at,
        ),
        NamingFrame(
          target: 'M31',
          filter: 'L',
          exposureSeconds: 120,
          number: 1,
          takenAt: at,
          sensorTempC: -10,
        ),
      ),
    );
    final stem = parts.removeLast();
    return NamingPatternCheck._(null, [...parts, '$stem.$extension'].join('/'));
  }
}

/// [NamingPattern.check]'s answer.
class NamingPatternCheck {
  const NamingPatternCheck._(this.error, this.preview);

  /// Why the pattern cannot name a frame, or null when it can.
  final String? error;

  /// The example path, extension included, the pattern gives; null with an
  /// [error].
  final String? preview;

  bool get isValid => error == null;
}

/// The values a capture step fixes for every frame it takes.
class NamingStep {
  const NamingStep({
    required this.frameType,
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
    this.camera,
    this.telescope,
    this.sequence,
    required this.session,
  });

  /// The step of a secondary camera rig labeled [rigLabel], which also stands
  /// for the camera, the telescope and the plan; it takes light frames.
  NamingStep.secondaryRig({
    required String rigLabel,
    required int? gain,
    required int? offset,
    required this.binX,
    required this.binY,
    required this.session,
  }) : frameType = FrameType.light,
       gain = gain ?? 0,
       offset = offset ?? 0,
       camera = rigLabel,
       telescope = rigLabel,
       sequence = rigLabel;

  final FrameType frameType;
  final int gain;
  final int offset;
  final int binX;
  final int binY;

  /// The camera's and the mount's names; blank or null reads as "Camera" and
  /// "Telescope", so an unnamed rig still gets one stable path.
  final String? camera;
  final String? telescope;

  /// The plan's name; null for a frame outside a sequence, which reads as
  /// the literal "Sequence" (never the target, which would label a plain
  /// target folder as a sequence).
  final String? sequence;

  /// When the night's session started: a run's send time, a manual frame's
  /// own time, so a night past UTC midnight stays one session.
  final DateTime session;
}

/// The values of one frame.
class NamingFrame {
  const NamingFrame({
    this.target,
    this.filter,
    required this.exposureSeconds,
    required this.number,
    required this.takenAt,
    this.sensorTempC,
  });

  final String? target;
  final String? filter;
  final double exposureSeconds;
  final int number;
  final DateTime takenAt;

  /// Null when the camera reports none, which reads as 0 °C.
  final double? sensorTempC;
}

/// One `$TOKEN` of the naming pattern.
///
/// A token with a [runPlaceholder] changes from frame to frame or is known
/// only to the run (the target a scheduler picked, the filter in the wheel,
/// an adapted exposure); a run fills it in itself from the sequencer's
/// variable catalog, formatted as the manual value is. Every other token is
/// fixed by the capture step. The labels, placeholders and the run's
/// variables are pinned against the sequencer by
/// `test_fixtures/frame_naming/run_tokens.json`.
enum NamingToken {
  target(r'$TARGET', 'target', runPlaceholder: r'${target.name}'),
  filter(r'$FILTER', 'filter', runPlaceholder: r'${filter}'),
  exposureTime(
    r'$EXPTIME',
    'exposure in seconds',
    runPlaceholder: r'${exposure.duration:.1f}',
  ),
  exposure(
    r'$EXPOSURE',
    r'same as $EXPTIME',
    runPlaceholder: r'${exposure.duration:.1f}',
  ),
  date(r'$DATE', 'UTC date', runPlaceholder: r'${time.date}'),
  time(r'$TIME', 'UTC time', runPlaceholder: r'${time.clock}'),
  dateTime(
    r'$DATETIME',
    'UTC date and time',
    runPlaceholder: r'${time.date}_${time.clock}',
  ),
  frameType(r'$FRAMETYPE', 'light, dark, flat or bias'),
  frameNumber(r'$FRAMENUM', 'frame number', runPlaceholder: r'${frame:04}'),
  seq(r'$SEQ', r'same as $FRAMENUM', runPlaceholder: r'${frame:04}'),
  gain(r'$GAIN', 'gain'),
  offset(r'$OFFSET', 'offset'),
  temperature(
    r'$TEMP',
    'sensor temperature',
    runPlaceholder: r'${camera.temp_c:.0f}C',
  ),
  binning(r'$BINNING', 'binning'),
  camera(r'$CAMERA', 'camera'),
  telescope(r'$TELESCOPE', 'mount'),
  sequence(r'$SEQUENCE', 'sequence'),
  session(r'$SESSION', 'night (UTC date the session started)');

  const NamingToken(this.text, this.meaning, {this.runPlaceholder});

  /// The token as written in a pattern, `$` included.
  final String text;

  /// What the token stands for, in words for the operator.
  final String meaning;

  /// The run's own template for this token, or null when the capture step
  /// fixes its value.
  final String? runPlaceholder;

  /// This token's value for [frame] of [step]. Without a [frame], a token
  /// with a [runPlaceholder] has none.
  String? valueFor(NamingStep step, [NamingFrame? frame]) => switch (this) {
    target =>
      frame == null
          ? null
          : _orIfBlank(
              frame.target,
              NamingPattern.noTargetLabel(step.frameType),
            ),
    filter =>
      frame == null
          ? null
          : _orIfBlank(frame.filter, NamingPattern.noFilterLabel),
    exposureTime || exposure => frame?.exposureSeconds.toStringAsFixed(1),
    date => frame == null ? null : _date(frame.takenAt),
    time => frame == null ? null : _clock(frame.takenAt),
    dateTime =>
      frame == null ? null : '${_date(frame.takenAt)}_${_clock(frame.takenAt)}',
    frameNumber || seq => frame?.number.toString().padLeft(4, '0'),
    temperature =>
      frame == null ? null : '${(frame.sensorTempC ?? 0).toStringAsFixed(0)}C',
    frameType => step.frameType.name,
    gain => '${step.gain}',
    offset => '${step.offset}',
    binning => '${step.binX}x${step.binY}',
    camera => _orIfBlank(step.camera, 'Camera'),
    telescope => _orIfBlank(step.telescope, 'Telescope'),
    sequence => step.sequence ?? 'Sequence',
    session => _date(step.session).replaceAll('-', ''),
  };

  static String _orIfBlank(String? value, String otherwise) =>
      (value == null || value.trim().isEmpty) ? otherwise : value;

  static String _date(DateTime at) =>
      at.toUtc().toIso8601String().substring(0, 10);

  static String _clock(DateTime at) =>
      at.toUtc().toIso8601String().substring(11, 19).replaceAll(':', '-');
}
