import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/calibration/fits_header_reader.dart';
import 'package:skotiq_core/src/services/science/moving_object_linker.dart';
import 'package:skotiq_core/src/services/wcs/frame_image_size.dart';

/// A monolithic XISF file as Skotiq writes one: signature, header length,
/// reserved field, XML header, then (unused here) the pixel block.
File _xisf(Directory dir) {
  const xml =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<xisf version="1.0" xmlns="http://www.pixinsight.com/xisf">'
      '<Image geometry="1920:1080:1" sampleFormat="UInt16" colorSpace="Gray" '
      'location="attachment:4096:4147200">'
      '<Property id="Instrument:ExposureTime" type="Float32" value="120"/>'
      '<FITSKeyword name="EXPTIME" value="120.0" comment="Exposure time [s]"/>'
      '<FITSKeyword name="DATE-OBS" value="\'2026-11-12T10:09:20.644\'" '
      'comment=""/>'
      '<FITSKeyword name="FILTER" value="\'O&apos;III\'" comment=""/>'
      '<FITSKeyword name="INSTRUME" value="\'Sim &amp; Co\'" comment=""/>'
      '<FITSKeyword name="HISTORY" value="" comment="calibrated"/>'
      '</Image><Metadata/></xisf>';
  final header = utf8.encode(xml);
  final bytes = BytesBuilder()
    ..add(ascii.encode('XISF0100'))
    ..add(
      (ByteData(
        4,
      )..setUint32(0, header.length, Endian.little)).buffer.asUint8List(),
    )
    ..add(Uint8List(4))
    ..add(header);
  final file = File('${dir.path}/frame.xisf')
    ..writeAsBytesSync(bytes.takeBytes());
  return file;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('xisf_headers'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('an XISF frame reports its size from its geometry', () async {
    final size = await readFrameImageSize(_xisf(dir).path);
    expect(size, (width: 1920, height: 1080));
  });

  test('an XISF frame gives its FITS keywords as card value text', () async {
    final header = await const FitsHeaderReader().readPrimaryHeader(
      _xisf(dir).path,
    );
    expect(FitsHeaderReader.doubleValue(header, 'EXPTIME'), 120.0);
    expect(FitsHeaderReader.stringValue(header, 'FILTER'), "O'III");
    expect(FitsHeaderReader.stringValue(header, 'INSTRUME'), 'Sim & Co');
    expect(FitsHeaderReader.intValue(header, 'NAXIS1'), 1920);
    expect(FitsHeaderReader.intValue(header, 'NAXIS2'), 1080);
    expect(header.containsKey('HISTORY'), isFalse);
  });

  test('the moving-object linker reads an XISF frame\'s timing', () async {
    final summary = await readFitsFrameSummary(_xisf(dir).path);
    expect(summary?.width, 1920);
    expect(summary?.exposureSeconds, 120.0);
    expect(summary?.filter, "O'III");
    expect(summary?.dateObs, DateTime.utc(2026, 11, 12, 10, 9, 20, 644));
  });

  test('a file that is neither format reads as nothing', () async {
    final other = File('${dir.path}/notes.txt')..writeAsStringSync('hello');
    expect(await readFrameImageSize(other.path), isNull);
    expect(await readFitsFrameSummary(other.path), isNull);
  });
}
