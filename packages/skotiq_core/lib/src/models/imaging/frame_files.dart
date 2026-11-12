/// The image files Skotiq opens as frames, by extension (lower case, no dot).
///
/// The native image seam (`frame_extensions()` in
/// `native/skotiq_native/imaging/src/frame_io.rs`) is what actually reads
/// them; this is its list on the Dart side, for file pickers, thumbnails and
/// path checks. `test/models/imaging/frame_files_test.dart` keeps the two in
/// step.
abstract final class FrameFiles {
  static const List<String> fits = ['fits', 'fit', 'fts'];
  static const List<String> xisf = ['xisf'];

  /// Every maker's raw format: Canon (CR2, CR3, CRW), Nikon (NEF, NRW), Sony
  /// (ARW, SRF, SR2), Fujifilm (RAF), Pentax (PEF), Adobe and others (DNG),
  /// Olympus and OM System (ORF), Panasonic and Leica (RW2, RAW), Minolta
  /// (MRW), Epson (ERF), Hasselblad (3FR).
  static const List<String> cameraRaw = [
    'cr2', 'cr3', 'nef', 'nrw', 'arw', 'srf', 'sr2', 'raf', 'pef', 'dng', //
    'orf', 'rw2', 'raw', 'crw', 'mrw', 'erf', '3fr',
  ];

  /// Everything above: what a frame picker offers.
  static const List<String> all = [...fits, ...xisf, ...cameraRaw];

  static String _extension(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// Whether [path] names a frame file Skotiq opens (none of which Flutter's
  /// image decoders can show).
  static bool isFrame(String path) => all.contains(_extension(path));

  static bool isCameraRaw(String path) => cameraRaw.contains(_extension(path));
}
