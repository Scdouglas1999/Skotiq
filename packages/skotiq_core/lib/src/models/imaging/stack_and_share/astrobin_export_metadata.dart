part of '../stack_and_share_models.dart';

/// AstroBin-style acquisition metadata for a stacked image.
///
/// Produces the standard acquisition block AstroBin expects: an integration
/// summary plus equipment details, renderable as Markdown for a forum/social
/// post or serialised to JSON for an API submission.
class AstroBinExportMetadata {
  /// Image / target title.
  final String? title;

  /// AstroBin subject type (e.g. `'Deep sky'`, `'Solar system'`).
  final String subjectType;

  /// Total integration time in seconds.
  final double integrationSecs;

  /// Number of light frames integrated.
  final int frames;

  /// Telescope / optical train description.
  final String? telescope;

  /// Camera description.
  final String? camera;

  /// Filter used, if single-filter.
  final String? filter;

  /// Focal length in millimetres.
  final double? focalLength;

  /// Aperture in millimetres.
  final double? aperture;

  /// The night the frames were acquired. AstroBin requires a date on every
  /// acquisition row, so an export without one cannot be imported at all — the
  /// user has to retype the whole session.
  final DateTime? date;

  const AstroBinExportMetadata({
    this.title,
    this.subjectType = 'Deep sky',
    required this.integrationSecs,
    required this.frames,
    this.telescope,
    this.camera,
    this.filter,
    this.focalLength,
    this.aperture,
    this.date,
  });

  /// The acquisition date in AstroBin's `YYYY-MM-DD` form, or null.
  String? get dateIso {
    final d = date;
    if (d == null) return null;
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  /// Per-frame exposure in seconds, derived from total integration and frame
  /// count. Returns `0` when there are no frames (rather than dividing by zero).
  double get perFrameExposureSecs {
    if (frames <= 0) return 0;
    return integrationSecs / frames;
  }

  /// Integration time formatted as zero-padded `HH:MM:SS`, the canonical form
  /// for an AstroBin acquisition block.
  String get integrationHms => formatHms(integrationSecs);

  /// Focal ratio (f-number), if both [focalLength] and [aperture] are known and
  /// the aperture is non-zero.
  double? get focalRatio {
    final fl = focalLength;
    final ap = aperture;
    if (fl == null || ap == null || ap <= 0) return null;
    return fl / ap;
  }

  AstroBinExportMetadata copyWith({
    String? title,
    String? subjectType,
    double? integrationSecs,
    int? frames,
    String? telescope,
    String? camera,
    String? filter,
    double? focalLength,
    double? aperture,
    DateTime? date,
  }) {
    return AstroBinExportMetadata(
      title: title ?? this.title,
      subjectType: subjectType ?? this.subjectType,
      integrationSecs: integrationSecs ?? this.integrationSecs,
      frames: frames ?? this.frames,
      telescope: telescope ?? this.telescope,
      camera: camera ?? this.camera,
      filter: filter ?? this.filter,
      focalLength: focalLength ?? this.focalLength,
      aperture: aperture ?? this.aperture,
      date: date ?? this.date,
    );
  }

  /// Renders the acquisition block as Markdown suitable for an AstroBin
  /// description or a social post.
  ///
  /// Always includes the **Integration** line with the `HH:MM:SS` HMS string,
  /// the frames × exposure breakdown, and the subject type; equipment lines are
  /// included only when their corresponding fields are populated.
  String toMarkdown() {
    final buf = StringBuffer();
    final heading = title?.trim();
    if (heading != null && heading.isNotEmpty) {
      buf.writeln('## $heading');
      buf.writeln();
    }

    final acquired = dateIso;
    if (acquired != null) buf.writeln('**Date:** $acquired');
    buf.writeln('**Subject type:** $subjectType');
    buf.writeln('**Frames:** $frames x ${_trimNum(perFrameExposureSecs)}s');
    buf.writeln('**Integration:** $integrationHms');

    final tele = telescope?.trim();
    if (tele != null && tele.isNotEmpty) {
      buf.writeln('**Telescope:** $tele');
    }
    final cam = camera?.trim();
    if (cam != null && cam.isNotEmpty) {
      buf.writeln('**Camera:** $cam');
    }
    final filt = filter?.trim();
    if (filt != null && filt.isNotEmpty) {
      buf.writeln('**Filter:** $filt');
    }
    if (focalLength != null) {
      buf.writeln('**Focal length:** ${_trimNum(focalLength!)} mm');
    }
    if (aperture != null) {
      buf.writeln('**Aperture:** ${_trimNum(aperture!)} mm');
    }
    final fRatio = focalRatio;
    if (fRatio != null) {
      buf.writeln('**Focal ratio:** f/${fRatio.toStringAsFixed(1)}');
    }

    return buf.toString().trimRight();
  }

  /// Serialises the metadata to a JSON-compatible map. Optional fields are
  /// omitted when null so the payload stays minimal.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'subjectType': subjectType,
      'integrationSecs': integrationSecs,
      'integrationHms': integrationHms,
      'frames': frames,
      'perFrameExposureSecs': perFrameExposureSecs,
    };
    final acquired = dateIso;
    if (acquired != null) json['date'] = acquired;
    if (title != null) json['title'] = title;
    if (telescope != null) json['telescope'] = telescope;
    if (camera != null) json['camera'] = camera;
    if (filter != null) json['filter'] = filter;
    if (focalLength != null) json['focalLength'] = focalLength;
    if (aperture != null) json['aperture'] = aperture;
    final fRatio = focalRatio;
    if (fRatio != null) json['focalRatio'] = fRatio;
    return json;
  }

  factory AstroBinExportMetadata.fromJson(Map<String, dynamic> json) {
    return AstroBinExportMetadata(
      title: json['title'] as String?,
      subjectType: (json['subjectType'] as String?) ?? 'Deep sky',
      integrationSecs: (json['integrationSecs'] as num?)?.toDouble() ?? 0,
      frames: (json['frames'] as num?)?.toInt() ?? 0,
      telescope: json['telescope'] as String?,
      camera: json['camera'] as String?,
      filter: json['filter'] as String?,
      focalLength: (json['focalLength'] as num?)?.toDouble(),
      aperture: (json['aperture'] as num?)?.toDouble(),
      date: DateTime.tryParse((json['date'] as String?) ?? ''),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AstroBinExportMetadata &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          subjectType == other.subjectType &&
          integrationSecs == other.integrationSecs &&
          frames == other.frames &&
          telescope == other.telescope &&
          camera == other.camera &&
          filter == other.filter &&
          focalLength == other.focalLength &&
          aperture == other.aperture &&
          dateIso == other.dateIso;

  @override
  int get hashCode => Object.hash(
    title,
    subjectType,
    integrationSecs,
    frames,
    telescope,
    camera,
    filter,
    focalLength,
    aperture,
    dateIso,
  );

  /// The acquisition row as AstroBin's import CSV.
  ///
  /// AstroBin's acquisition importer reads a header row and one row per
  /// acquisition session; `date`, `number` and `duration` are the three fields
  /// it needs to build a long-exposure acquisition, and they are exactly the
  /// three a user would otherwise retype from this screen. The filter column is
  /// deliberately NOT emitted: AstroBin keys filters by their equipment-database
  /// id, which Skotiq does not hold, and a filter NAME there would break the
  /// import rather than fill it in — the filter stays in the Markdown block for
  /// the user to set once.
  ///
  /// Returns null when there is no acquisition date: every AstroBin row needs
  /// one, so a dateless CSV would import as nothing.
  String? toAstroBinCsv() {
    final acquired = dateIso;
    if (acquired == null) return null;
    final duration = _trimNum(perFrameExposureSecs);
    return 'date,number,duration\n$acquired,$frames,$duration\n';
  }
}

/// Formats a duration in seconds as zero-padded `HH:MM:SS`.
///
/// Negative inputs are treated as zero. This is the canonical acquisition-block
/// format (distinct from the compact `2h12m` watermark form used elsewhere).
String formatHms(double seconds) {
  final total = seconds <= 0 ? 0 : seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}

/// Formats a number without a trailing `.0` for whole values, otherwise with a
/// single decimal place (e.g. `120` → `'120'`, `2.5` → `'2.5'`).
String _trimNum(double value) {
  if (value == value.roundToDouble()) {
    return value.round().toString();
  }
  return value.toStringAsFixed(1);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}
