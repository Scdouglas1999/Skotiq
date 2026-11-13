import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('the Dart list names exactly the native seam\'s extensions', () {
    final source = File(
      '../../native/skotiq_native/imaging/src/frame_io.rs',
    ).readAsStringSync();
    final native = <String>{};
    for (final block in RegExp(
      r'fn extensions\(&self\) -> &.static \[&.static str\] \{\s*&\[([^\]]*)\]',
    ).allMatches(source)) {
      native.addAll(
        RegExp(r'"([a-z0-9]+)"').allMatches(block.group(1)!).map((m) => m.group(1)!),
      );
    }
    expect(native, isNotEmpty);
    // XISF is read by the native side through its own reader as well.
    expect({...FrameFiles.all}..removeAll(FrameFiles.xisf), native..removeAll(FrameFiles.xisf));
  });

  test('frame paths are recognized by extension, case and folders aside', () {
    expect(FrameFiles.isFrame('/night/M31_0001.fits'), isTrue);
    expect(FrameFiles.isFrame(r'C:\Lights\IMG_0001.CR3'), isTrue);
    expect(FrameFiles.isFrame('DSCF1234.RAF'), isTrue);
    expect(FrameFiles.isFrame('preview.jpg'), isFalse);
    expect(FrameFiles.isFrame('/folder.fits/notes'), isFalse);
    expect(FrameFiles.isCameraRaw('_DSC0001.ARW'), isTrue);
    expect(FrameFiles.isCameraRaw('master.xisf'), isFalse);
  });

  test('a captured-image record names the format of the file it points at', () {
    expect(frameFileFormatOf('/n/M31_0001.fits').recordName, 'fits');
    expect(frameFileFormatOf('/n/M31_0001.xisf').recordName, 'xisf');
    expect(frameFileFormatOf('/n/IMG_0001.CR2').recordName, 'raw');
    for (final format in ImageFileFormat.values) {
      expect(ImageFileFormat.fromRecord(format.recordName), format);
    }
    expect(ImageFileFormat.fromRecord('fit'), ImageFileFormat.fits);
    expect(ImageFileFormat.fromRecord('bmp'), isNull);
  });
}
