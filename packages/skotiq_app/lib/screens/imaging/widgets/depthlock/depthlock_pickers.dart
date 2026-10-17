import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// File choosers DepthLock needs, behind provider seams so a widget test can
/// answer them without a platform dialog (the pattern
/// `defectMapLocalDarkPickerProvider` established).

/// Picks one FITS file — a master dark, a master flat, or a reference frame.
typedef DepthLockFilePicker = Future<String?> Function(String title);

/// Picks any number of saved lights to offer to a goal.
typedef DepthLockFramesPicker = Future<List<String>> Function();

const XTypeGroup _fitsFiles = XTypeGroup(
  label: 'FITS images',
  extensions: <String>['fits', 'fit', 'fts'],
);

Future<String?> _pickFile(String title) async {
  final file = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[_fitsFiles],
    confirmButtonText: 'Select',
  );
  return file?.path;
}

Future<List<String>> _pickFrames() async {
  final files = await openFiles(
    acceptedTypeGroups: const <XTypeGroup>[_fitsFiles],
  );
  return files.map((file) => file.path).toList(growable: false);
}

/// Chooser for a single DepthLock path (master dark / master flat).
final depthLockFilePickerProvider = Provider<DepthLockFilePicker>(
  (ref) => _pickFile,
);

/// Chooser for the frames offered to a goal by hand.
final depthLockFramesPickerProvider = Provider<DepthLockFramesPicker>(
  (ref) => _pickFrames,
);
