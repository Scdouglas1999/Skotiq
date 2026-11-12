/// What a frame's recorded gain number is.
///
/// Every new DSLR or mirrorless frame records its ISO speed as its gain
/// ([iso]); every astronomy camera frame its gain ([gain]). Frames a DSLR
/// took through gPhoto2 before Skotiq recorded ISO speeds stored the
/// position in the camera's ISO list instead ([isoListPosition]); their ISO
/// is unknown, so nothing compares them by gain.
enum GainKind {
  gain('gain'),
  iso('iso'),
  isoListPosition('isoListPosition');

  const GainKind(this.recordName);

  /// The `captured_images.gain_kind` value.
  final String recordName;

  static GainKind fromRecord(String? value) => GainKind.values.firstWhere(
    (kind) => kind.recordName == value,
    orElse: () => GainKind.gain,
  );

  /// Whether [GainKind] leaves a frame's gain comparable with another's.
  bool get isKnown => this != GainKind.isoListPosition;

  /// The field label for a frame's gain: "Gain" or "ISO".
  String get label => this == GainKind.gain ? 'Gain' : 'ISO';

  /// [value] under [label]: "800", or the ISO-list position.
  String valueText(int value) => this == GainKind.isoListPosition
      ? 'unknown (ISO-list position $value)'
      : '$value';

  /// [value] as a frame records it: "gain 100", "ISO 800", or the ISO-list
  /// position an older DSLR frame stored.
  String describe(int value) => switch (this) {
    GainKind.gain => 'gain $value',
    GainKind.iso => 'ISO $value',
    GainKind.isoListPosition => 'unknown ISO (ISO-list position $value)',
  };
}
