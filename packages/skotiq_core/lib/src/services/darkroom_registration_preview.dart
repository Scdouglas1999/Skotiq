import 'dart:ui' show Offset;

/// Where one light lands on the grid, as the registration pre-pass found it.
class DarkroomFramePreview {
  const DarkroomFramePreview({
    required this.path,
    required this.group,
    required this.included,
    this.side,
    this.corners,
    this.overlap,
    this.rotationDeg,
    this.starsMatched,
    this.rmsPx,
    this.failure,
    this.reason,
    required this.raw,
  });

  final String path;

  /// Calibration group label (night, filter and settings).
  final String group;

  /// Pier side as recorded at capture, when known.
  final String? side;

  /// Fully supported footprint on the grid, in grid pixels.
  final List<Offset>? corners;
  final double? overlap;
  final double? rotationDeg;
  final int? starsMatched;
  final double? rmsPx;

  /// Why registration failed; null when it succeeded.
  final String? failure;

  /// Whether the build would include this light.
  final bool included;

  /// Why it is not included.
  final String? reason;

  /// The native record, passed back so a later pass reuses it.
  final Map<String, dynamic> raw;

  factory DarkroomFramePreview.fromJson(Map<String, dynamic> json) {
    final corners = json['corners'] as List?;
    return DarkroomFramePreview(
      path: json['path'] as String,
      group: json['group'] as String? ?? '',
      side: json['side'] as String?,
      corners: corners == null
          ? null
          : [
              for (final c in corners)
                Offset(
                  ((c as List)[0] as num).toDouble(),
                  (c[1] as num).toDouble(),
                ),
            ],
      overlap: (json['overlap'] as num?)?.toDouble(),
      rotationDeg: (json['rotationDeg'] as num?)?.toDouble(),
      starsMatched: (json['starsMatched'] as num?)?.toInt(),
      rmsPx: (json['rmsPx'] as num?)?.toDouble(),
      failure: json['failure'] as String?,
      included: json['included'] == true,
      reason: json['reason'] as String?,
      raw: json,
    );
  }
}

/// A light whose footprint bounds the common crop.
class DarkroomLimitingFrame {
  const DarkroomLimitingFrame({
    required this.path,
    required this.group,
    required this.retainedWithout,
  });
  final String path;
  final String group;

  /// Retained fraction of the field if this light alone is excluded.
  final double retainedWithout;

  factory DarkroomLimitingFrame.fromJson(Map<String, dynamic> json) =>
      DarkroomLimitingFrame(
        path: json['path'] as String,
        group: json['group'] as String? ?? '',
        retainedWithout: (json['retainedWithout'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
    'path': path,
    'group': group,
    'retainedWithout': retainedWithout,
  };
}

/// The registration pre-pass: every light's footprint and the common crop.
class DarkroomRegistrationPreview {
  const DarkroomRegistrationPreview({
    required this.width,
    required this.height,
    required this.frames,
    required this.crop,
    required this.retainedArea,
    required this.minRetainedArea,
    required this.meetsMinimum,
    required this.limiting,
  });

  final int width;
  final int height;
  final List<DarkroomFramePreview> frames;

  /// `[x0, y0, x1, y1]`, end-exclusive; null when nothing is covered by every
  /// included light.
  final List<int>? crop;
  final double retainedArea;
  final double minRetainedArea;
  final bool meetsMinimum;
  final List<DarkroomLimitingFrame> limiting;

  Iterable<DarkroomFramePreview> get included =>
      frames.where((f) => f.included);
  Iterable<DarkroomFramePreview> get notIncluded =>
      frames.where((f) => !f.included);

  factory DarkroomRegistrationPreview.fromJson(Map<String, dynamic> json) {
    final crop = json['crop'] as List?;
    return DarkroomRegistrationPreview(
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      frames: [
        for (final f in json['frames'] as List)
          DarkroomFramePreview.fromJson(Map<String, dynamic>.from(f as Map)),
      ],
      crop: crop?.map((v) => (v as num).toInt()).toList(),
      retainedArea: (json['retainedArea'] as num).toDouble(),
      minRetainedArea: (json['minRetainedArea'] as num).toDouble(),
      meetsMinimum: json['meetsMinimum'] == true,
      limiting: [
        for (final f in json['limiting'] as List? ?? const [])
          DarkroomLimitingFrame.fromJson(Map<String, dynamic>.from(f as Map)),
      ],
    );
  }

  /// The native record this was read from, so a saved pre-pass reads back
  /// identically and its footprints can be reused.
  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'frames': [for (final f in frames) f.raw],
    'crop': crop,
    'retainedArea': retainedArea,
    'minRetainedArea': minRetainedArea,
    'meetsMinimum': meetsMinimum,
    'limiting': [for (final f in limiting) f.toJson()],
  };

  /// One sentence naming the frames that limit the crop, for errors and
  /// notifications.
  String describeLimit({int names = 3}) {
    final retained = '${(retainedArea * 100).toStringAsFixed(1)}%';
    final minimum = '${(minRetainedArea * 100).toStringAsFixed(0)}%';
    if (limiting.isEmpty) {
      return 'The common crop keeps $retained of the field (minimum $minimum).';
    }
    final named = limiting
        .take(names)
        .map(
          (f) =>
              '${_basename(f.path)} (${(f.retainedWithout * 100).toStringAsFixed(1)}% without it)',
        )
        .join(', ');
    final more = limiting.length > names
        ? ' and ${limiting.length - names} more'
        : '';
    return 'The common crop keeps $retained of the field (minimum $minimum). '
        'Limited by $named$more.';
  }
}

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;
