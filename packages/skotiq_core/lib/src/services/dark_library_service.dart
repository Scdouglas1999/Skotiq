import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database/database.dart';
import '../database/daos/dark_library_dao.dart';
import '../models/calibration/dark_library_match_tolerances.dart';

/// Service for managing dark frame library operations.
///
/// Handles registering captured darks/biases, finding the best match for
/// auto-subtraction, creating master darks via median combination, performing
/// pixel-by-pixel dark subtraction, and cleaning orphaned entries.
class DarkLibraryService {
  final DarkLibraryDao _dao;

  DarkLibraryService(this._dao);

  // Registration

  /// Register a captured dark or bias frame in the library.
  ///
  /// [filePath] must point to an existing FITS/XISF file on disk.
  /// Returns the database ID of the new entry.
  Future<int> addDarkFrame({
    required String filePath,
    required double exposureTime,
    required String frameType,
    double? temperature,
    int gain = 0,
    int offset = 0,
    int binX = 1,
    int binY = 1,
    int? width,
    int? height,
  }) {
    if (frameType != 'dark' && frameType != 'bias') {
      throw ArgumentError(
        'frameType must be "dark" or "bias", got "$frameType"',
      );
    }
    return _dao.addEntry(
      DarkLibraryCompanion.insert(
        filePath: filePath,
        exposureTime: exposureTime,
        frameType: Value(frameType),
        temperature: Value(temperature),
        gain: Value(gain),
        offset: Value(offset),
        binX: Value(binX),
        binY: Value(binY),
        width: Value(width),
        height: Value(height),
      ),
    );
  }

  // Matching

  /// Find the best-matching dark or bias for a light frame's parameters.
  ///
  /// Matching rules:
  /// - Exposure must be within [tolerances.exposureSecs] (default ±0.5s).
  /// - Gain, offset, and binning must match exactly.
  /// - Temperature must be within [tolerances.temperatureC] (default ±1.0°C).
  /// - Master darks are preferred over individual raw frames.
  /// - Among matches, the closest temperature match wins.
  ///
  /// The tolerances object MUST be the same one consulted by
  /// `DarkLibraryCoverageService`. Resolve it from
  /// `darkLibraryMatchTolerancesProvider` at the caller so the coverage UI
  /// and the runtime matcher cannot drift apart again.
  Future<DarkLibraryEntry?> findMatchingDark({
    required double exposureTime,
    required int gain,
    int offset = 0,
    int binX = 1,
    int binY = 1,
    double? temperature,
    DarkLibraryMatchTolerances tolerances = DarkLibraryMatchTolerances.defaults,
    String frameType = 'dark',
  }) {
    return _dao.findBestMatch(
      exposureTime: exposureTime,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      temperature: temperature,
      tolerances: tolerances,
      frameType: frameType,
    );
  }

  // Master dark creation

  /// Create a master dark by median-combining a list of raw dark frames.
  ///
  /// The input frames must all share the same exposure, gain, binning, and
  /// dimensions. The result is written to [outputPath] and registered in the
  /// library.
  ///
  /// Returns the database ID of the new master dark entry.
  Future<int> createMasterDark({
    required List<DarkLibraryEntry> frames,
    required String outputPath,
  }) async {
    if (frames.isEmpty) {
      throw ArgumentError('frames must not be empty');
    }
    if (frames.length < 2) {
      throw ArgumentError('Need at least 2 frames to create a master dark');
    }

    // Validate all frames share matching parameters
    final first = frames.first;
    for (final frame in frames.skip(1)) {
      if (frame.exposureTime != first.exposureTime ||
          frame.gain != first.gain ||
          frame.offset != first.offset ||
          frame.binX != first.binX ||
          frame.binY != first.binY ||
          frame.frameType != first.frameType) {
        throw ArgumentError(
          'All frames must have matching exposure, gain, offset, binning, '
          'and frame type. Mismatch found: '
          '${frame.exposureTime}s/gain${frame.gain}/offset${frame.offset}/'
          '${frame.binX}x${frame.binY}/${frame.frameType} vs '
          '${first.exposureTime}s/gain${first.gain}/offset${first.offset}/'
          '${first.binX}x${first.binY}/${first.frameType}',
        );
      }
    }

    // Read raw pixel data from each FITS file and median-combine
    final pixelSets = <Uint16List>[];
    int? imgWidth;
    int? imgHeight;

    for (final frame in frames) {
      final file = File(frame.filePath);
      if (!await file.exists()) {
        throw StateError('Dark frame file not found: ${frame.filePath}');
      }
      final bytes = await file.readAsBytes();
      final parsed = _parseFitsPixels(bytes);
      if (imgWidth != null &&
          (parsed.width != imgWidth || parsed.height != imgHeight)) {
        throw ArgumentError(
          'All frames must have matching dimensions. ${frame.filePath} is '
          '${parsed.width}x${parsed.height}; expected ${imgWidth}x$imgHeight.',
        );
      }
      imgWidth ??= parsed.width;
      imgHeight ??= parsed.height;
      pixelSets.add(parsed.pixels);
    }

    if (imgWidth == null || imgHeight == null) {
      throw StateError('Could not determine image dimensions from FITS files');
    }

    // Median combine in an isolate to avoid blocking the UI thread
    final masterPixels = await compute(
      _medianCombine,
      _MedianCombineParams(pixelSets, imgWidth * imgHeight),
    );

    // Write the master dark FITS file
    await _writeFitsFile(outputPath, masterPixels, imgWidth, imgHeight);

    // Compute average temperature across input frames
    double? avgTemp;
    final temps = frames
        .where((f) => f.temperature != null)
        .map((f) => f.temperature!);
    if (temps.isNotEmpty) {
      avgTemp = temps.reduce((a, b) => a + b) / temps.length;
    }

    // Register the master dark in the library
    return _dao.addEntry(
      DarkLibraryCompanion.insert(
        filePath: outputPath,
        exposureTime: first.exposureTime,
        frameType: Value(first.frameType),
        temperature: Value(avgTemp),
        gain: Value(first.gain),
        offset: Value(first.offset),
        binX: Value(first.binX),
        binY: Value(first.binY),
        width: Value(imgWidth),
        height: Value(imgHeight),
        masterDarkPath: Value(outputPath),
        masterFrameCount: Value(frames.length),
      ),
    );
  }

  // Dark subtraction

  /// Subtract a dark frame from a light frame, pixel by pixel.
  ///
  /// Both must have the same dimensions. Values are clamped to [0, 65535].
  /// Returns a new pixel buffer with the subtracted result.
  ///
  /// This operates on raw 16-bit pixel arrays.
  Future<Uint16List> subtractDark({
    required Uint16List lightPixels,
    required Uint16List darkPixels,
  }) async {
    if (lightPixels.length != darkPixels.length) {
      throw ArgumentError(
        'Light and dark frames must have the same number of pixels. '
        'Light: ${lightPixels.length}, Dark: ${darkPixels.length}',
      );
    }

    // Do subtraction in isolate to avoid jank
    return compute(_subtractPixels, _SubtractParams(lightPixels, darkPixels));
  }

  /// Load raw pixel data from a FITS file on disk.
  ///
  /// Returns the 16-bit pixel array. Throws if the file cannot be parsed.
  Future<Uint16List> loadDarkPixels(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('Dark frame file not found: $filePath');
    }
    final bytes = await file.readAsBytes();
    return _parseFitsPixels(bytes).pixels;
  }

  // Library management

  /// Get all entries in the library.
  Future<List<DarkLibraryEntry>> getAllEntries() => _dao.getAllEntries();

  /// Watch all entries (reactive stream).
  Stream<List<DarkLibraryEntry>> watchAllEntries() => _dao.watchAllEntries();

  /// Watch entries of a specific frame type.
  Stream<List<DarkLibraryEntry>> watchEntriesByType(String frameType) =>
      _dao.watchEntriesByFrameType(frameType);

  /// Get library statistics.
  Future<DarkLibraryStats> getLibraryStats() => _dao.getStats();

  /// Get distinct parameter groups present in the library.
  Future<List<DarkGroupKey>> getDistinctGroups() => _dao.getDistinctGroups();

  /// Get all raw frames matching specific parameters (for master dark creation).
  Future<List<DarkLibraryEntry>> getMatchingFrames({
    required double exposureTime,
    required int gain,
    int offset = 0,
    int binX = 1,
    int binY = 1,
    String frameType = 'dark',
  }) {
    return _dao.getMatchingFrames(
      exposureTime: exposureTime,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      frameType: frameType,
    );
  }

  /// Get all raw and master entries in one exact library group.
  Future<List<DarkLibraryEntry>> getEntriesForGroup(DarkGroupKey group) =>
      _dao.getEntriesForGroup(group);

  /// Delete a single entry and optionally remove the file from disk.
  Future<void> deleteEntry(int id, {bool deleteFile = false}) async {
    if (deleteFile) {
      final entry = await _dao.getEntryById(id);
      if (entry != null) {
        await _deleteFileIfExists(entry.filePath);
        if (entry.masterDarkPath != null) {
          await _deleteFileIfExists(entry.masterDarkPath!);
        }
      }
    }
    await _dao.deleteEntry(id);
  }

  /// Delete multiple entries and optionally remove files from disk.
  Future<void> deleteEntries(List<int> ids, {bool deleteFile = false}) async {
    if (deleteFile) {
      for (final id in ids) {
        final entry = await _dao.getEntryById(id);
        if (entry != null) {
          await _deleteFileIfExists(entry.filePath);
          if (entry.masterDarkPath != null) {
            await _deleteFileIfExists(entry.masterDarkPath!);
          }
        }
      }
    }
    await _dao.deleteEntries(ids);
  }

  /// Delete all entries and optionally remove files from disk.
  Future<void> clearLibrary({bool deleteFiles = false}) async {
    if (deleteFiles) {
      final entries = await _dao.getAllEntries();
      for (final entry in entries) {
        await _deleteFileIfExists(entry.filePath);
        if (entry.masterDarkPath != null) {
          await _deleteFileIfExists(entry.masterDarkPath!);
        }
      }
    }
    await _dao.deleteAll();
  }

  /// Remove entries whose files no longer exist on disk.
  ///
  /// Returns the number of orphaned entries removed.
  Future<int> cleanOrphanedEntries() async {
    final entries = await _dao.getAllEntries();
    final orphanIds = <int>[];

    for (final entry in entries) {
      final fileExists = await File(entry.filePath).exists();
      if (!fileExists) {
        orphanIds.add(entry.id);
      }
    }

    if (orphanIds.isNotEmpty) {
      await _dao.deleteEntries(orphanIds);
    }

    return orphanIds.length;
  }

  // Private helpers

  Future<void> _deleteFileIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Minimal FITS parser that extracts pixel data and normalizes to 16-bit
  /// unsigned samples.
  ///
  /// FITS format: 2880-byte header blocks with keyword=value cards, followed by
  /// a data block. We honour the following keywords:
  ///
  /// - `NAXIS1`, `NAXIS2`: image dimensions (required).
  /// - `BITPIX`: pixel encoding (see below).
  /// - `BZERO`, `BSCALE`: physical-value linear transform per the FITS spec
  ///   `physical = BSCALE * stored + BZERO`. Defaults are `BSCALE = 1.0` and
  ///   `BZERO = 0.0` for floating-point BITPIX, and `BZERO = 32768.0` for the
  ///   legacy 16-bit unsigned-via-signed convention (kept for byte-identical
  ///   parity with the original 16-bit path).
  ///
  /// Supported `BITPIX` values:
  ///
  /// - `16`  — signed 16-bit (big-endian) reinterpreted as unsigned with the
  ///   implicit `BZERO = 32768` offset Skotiq's own darks are written with.
  /// - `-32` — IEEE 754 single-precision float (big-endian, FITS spec). Used
  ///   by NINA, PixInsight, SiriL master darks. Converted to u16 via
  ///   `clamp(round(BSCALE * stored + BZERO), 0, 65535)`.
  /// - `-64` — IEEE 754 double-precision float (big-endian, FITS spec).
  ///   Same conversion as `-32`.
  ///
  /// Any other `BITPIX` is rejected with a `FormatException` listing the
  /// supported encodings.
  ///
  /// When float samples fall outside `[0, 65535]` after BZERO/BSCALE scaling,
  /// the parser saturates them and emits a single warning per file via
  /// `dart:developer` so users know their floating-point dynamic range was
  /// clipped to the dark library's 16-bit representation.
  _FitsPixelData _parseFitsPixels(Uint8List bytes) {
    // Parse header to find dimensions
    int width = 0;
    int height = 0;
    int bitpix = 16;
    int headerEnd = 0;
    // BZERO / BSCALE: physical = BSCALE * stored + BZERO.
    // We delay defaulting BZERO until we know BITPIX so the 16-bit path can
    // keep its implicit BZERO=32768 convention when the keyword is absent.
    double? bzeroFromHeader;
    double? bscaleFromHeader;

    // FITS headers are in 2880-byte blocks, each card is 80 chars
    bool endFound = false;
    for (
      int blockStart = 0;
      blockStart < bytes.length && !endFound;
      blockStart += 2880
    ) {
      for (
        int cardStart = blockStart;
        cardStart < blockStart + 2880 && cardStart + 80 <= bytes.length;
        cardStart += 80
      ) {
        final card = String.fromCharCodes(bytes, cardStart, cardStart + 80);

        if (card.startsWith('NAXIS1')) {
          width = _parseFitsIntValue(card);
        } else if (card.startsWith('NAXIS2')) {
          height = _parseFitsIntValue(card);
        } else if (card.startsWith('BITPIX')) {
          bitpix = _parseFitsIntValue(card);
        } else if (card.startsWith('BZERO')) {
          bzeroFromHeader = _parseFitsDoubleValue(card);
        } else if (card.startsWith('BSCALE')) {
          bscaleFromHeader = _parseFitsDoubleValue(card);
        } else if (card.startsWith('END')) {
          headerEnd = blockStart + 2880; // Data starts at next block boundary
          endFound = true;
          break;
        }
      }
    }

    if (!endFound || headerEnd == 0) {
      throw const FormatException('Invalid FITS file: missing END card');
    }

    if (width == 0 || height == 0) {
      throw FormatException(
        'Invalid FITS file: could not determine dimensions '
        '(NAXIS1=$width, NAXIS2=$height)',
      );
    }

    // Reject unsupported BITPIX loudly — list the supported encodings so the
    // user can fix their pipeline.
    const supportedBitpix = <int>[16, -32, -64];
    if (!supportedBitpix.contains(bitpix)) {
      throw FormatException(
        'Unsupported FITS BITPIX=$bitpix for dark library. '
        'Supported encodings: '
        '16 (unsigned 16-bit), '
        '-32 (IEEE float32), '
        '-64 (IEEE float64). '
        'BITPIX=8 (byte), 32 (int32), 64 (int64), and other values are not '
        'accepted because the dark library stores 16-bit unsigned samples.',
      );
    }

    final pixelCount = width * height;
    final bytesPerSample = (bitpix.abs()) ~/ 8;
    final dataOffset = headerEnd;
    final expectedDataBytes = pixelCount * bytesPerSample;
    if (dataOffset + expectedDataBytes > bytes.length) {
      throw FormatException(
        'Truncated FITS pixel data: expected $expectedDataBytes bytes, '
        'found ${bytes.length - dataOffset}',
      );
    }

    final pixels = Uint16List(pixelCount);
    int saturatedLow = 0;
    int saturatedHigh = 0;

    if (bitpix == 16) {
      // FITS stores 16-bit data as big-endian signed shorts; the BZERO=32768
      // convention encodes [0..65535] unsigned and is implicit when the
      // keyword is absent. This path applies no BSCALE.
      for (int i = 0; i < pixelCount; i++) {
        final bytePos = dataOffset + i * 2;
        final highByte = bytes[bytePos];
        final lowByte = bytes[bytePos + 1];
        final rawUnsigned = (highByte << 8) | lowByte;
        // Interpret as signed 16-bit: values > 32767 are negative
        final signedVal = rawUnsigned > 32767
            ? rawUnsigned - 65536
            : rawUnsigned;
        // Convert from signed to unsigned (BZERO=32768 convention):
        // physical_value = stored_value + BZERO
        // Range: -32768 + 32768 = 0  through  32767 + 32768 = 65535
        pixels[i] = signedVal + 32768;
      }
    } else {
      // Floating-point paths (BITPIX = -32 or -64).
      // FITS spec defaults for floats: BSCALE=1, BZERO=0.
      final bzero = bzeroFromHeader ?? 0.0;
      final bscale = bscaleFromHeader ?? 1.0;
      final bd = ByteData.sublistView(
        bytes,
        dataOffset,
        dataOffset + expectedDataBytes,
      );

      for (int i = 0; i < pixelCount; i++) {
        // FITS floats are big-endian per the spec.
        final stored = bitpix == -32
            ? bd.getFloat32(i * 4, Endian.big)
            : bd.getFloat64(i * 8, Endian.big);

        // Apply BZERO/BSCALE per the FITS linear transform.
        // NaN samples (common in float masters where rejected pixels become
        // NaN) collapse to zero so they don't poison the median combine
        // downstream.
        double physical;
        if (stored.isNaN) {
          physical = 0.0;
        } else {
          physical = bscale * stored + bzero;
        }

        if (physical <= 0.0) {
          if (physical < 0.0) saturatedLow++;
          pixels[i] = 0;
        } else if (physical >= 65535.0) {
          if (physical > 65535.0) saturatedHigh++;
          pixels[i] = 65535;
        } else {
          // Round-half-away-from-zero (physical is non-negative here).
          pixels[i] = (physical + 0.5).floor();
        }
      }
    }

    // Surface the path that was taken so users can correlate parse logs
    // against import failures. Warn loudly when clamping changes pixel values
    // — silently clamping would hide a real dynamic-range mismatch.
    final pathLabel = switch (bitpix) {
      16 => 'BITPIX=16 (uint16 via BZERO=32768 convention)',
      -32 => 'BITPIX=-32 (IEEE float32)',
      -64 => 'BITPIX=-64 (IEEE float64)',
      _ => 'BITPIX=$bitpix',
    };
    developer.log(
      'DarkLibraryService: parsed FITS $pathLabel ${width}x$height '
      '(BZERO=${bzeroFromHeader ?? "default"}, '
      'BSCALE=${bscaleFromHeader ?? "default"})',
      name: 'DarkLibraryService',
    );
    if (saturatedLow > 0 || saturatedHigh > 0) {
      developer.log(
        'DarkLibraryService: WARNING — clamped float pixels to u16 range. '
        'Below 0: $saturatedLow, above 65535: $saturatedHigh. '
        'If this was unexpected, check BZERO/BSCALE in your master dark.',
        name: 'DarkLibraryService',
        level: 900, // ~warning
      );
    }

    return _FitsPixelData(pixels, width, height);
  }

  int _parseFitsIntValue(String card) {
    // FITS card format: "KEYWORD = value / comment"
    final eqIdx = card.indexOf('=');
    if (eqIdx < 0) return 0;
    final afterEq = card.substring(eqIdx + 1);
    final slashIdx = afterEq.indexOf('/');
    final valStr = (slashIdx >= 0 ? afterEq.substring(0, slashIdx) : afterEq)
        .trim();
    return int.tryParse(valStr) ?? 0;
  }

  /// Parse a floating-point value from a FITS card, tolerating integer
  /// literals (e.g. `BZERO = 32768`) which the FITS spec also permits for
  /// numeric-valued keywords.
  double? _parseFitsDoubleValue(String card) {
    final eqIdx = card.indexOf('=');
    if (eqIdx < 0) return null;
    final afterEq = card.substring(eqIdx + 1);
    final slashIdx = afterEq.indexOf('/');
    final valStr = (slashIdx >= 0 ? afterEq.substring(0, slashIdx) : afterEq)
        .trim();
    if (valStr.isEmpty) return null;
    // double.tryParse accepts both "32768" and "32768.0" / "3.2768E4" so it
    // handles the integer-literal case the FITS spec allows for these
    // keywords.
    return double.tryParse(valStr);
  }

  /// Write a minimal valid FITS file with 16-bit unsigned pixel data.
  Future<void> _writeFitsFile(
    String path,
    Uint16List pixels,
    int width,
    int height,
  ) async {
    final headerCards = <String>[
      _fitsCard('SIMPLE', 'T'),
      _fitsCard('BITPIX', '16'),
      _fitsCard('NAXIS', '2'),
      _fitsCard('NAXIS1', '$width'),
      _fitsCard('NAXIS2', '$height'),
      _fitsCard('BZERO', '32768'),
      _fitsCard('BSCALE', '1'),
      'END${' ' * 77}',
    ];

    // Pad header to 2880-byte boundary
    final headerBytes = StringBuffer();
    for (final card in headerCards) {
      headerBytes.write(card);
    }
    final headerStr = headerBytes.toString();
    final headerLen = headerStr.length;
    final paddedHeaderLen = ((headerLen + 2879) ~/ 2880) * 2880;
    final fullHeader = headerStr.padRight(paddedHeaderLen, ' ');

    // Build data block (big-endian signed with BZERO=32768)
    final dataLen = width * height * 2;
    final paddedDataLen = ((dataLen + 2879) ~/ 2880) * 2880;
    final dataBytes = Uint8List(paddedDataLen);

    for (int i = 0; i < pixels.length; i++) {
      final signedVal = pixels[i] - 32768; // Apply BZERO
      final unsigned = signedVal & 0xFFFF;
      dataBytes[i * 2] = (unsigned >> 8) & 0xFF; // Big-endian high byte
      dataBytes[i * 2 + 1] = unsigned & 0xFF; // Big-endian low byte
    }

    // Write file
    final file = File(path);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    sink.add(fullHeader.codeUnits);
    sink.add(dataBytes);
    await sink.flush();
    await sink.close();
  }

  String _fitsCard(String keyword, String value) {
    final kw = keyword.padRight(8);
    final card = '$kw= ${value.padLeft(20)}';
    return card.padRight(80);
  }
}

/// Internal helper for FITS pixel parsing.
class _FitsPixelData {
  final Uint16List pixels;
  final int width;
  final int height;

  _FitsPixelData(this.pixels, this.width, this.height);
}

/// Parameters for median combine isolate.
class _MedianCombineParams {
  final List<Uint16List> frames;
  final int pixelCount;

  _MedianCombineParams(this.frames, this.pixelCount);
}

/// Median-combine multiple frames pixel by pixel.
/// Runs in an isolate via compute().
Uint16List _medianCombine(_MedianCombineParams params) {
  final result = Uint16List(params.pixelCount);
  final frameCount = params.frames.length;
  final values = List<int>.filled(frameCount, 0);

  for (int i = 0; i < params.pixelCount; i++) {
    for (int f = 0; f < frameCount; f++) {
      values[f] = params.frames[f][i];
    }
    values.sort();

    // Median: middle value for odd count, average of two middle for even
    if (frameCount.isOdd) {
      result[i] = values[frameCount ~/ 2];
    } else {
      final mid = frameCount ~/ 2;
      result[i] = ((values[mid - 1] + values[mid]) ~/ 2);
    }
  }

  return result;
}

/// Parameters for subtraction isolate.
class _SubtractParams {
  final Uint16List light;
  final Uint16List dark;

  _SubtractParams(this.light, this.dark);
}

/// Pixel-by-pixel dark subtraction. Runs in an isolate.
Uint16List _subtractPixels(_SubtractParams params) {
  final result = Uint16List(params.light.length);

  for (int i = 0; i < params.light.length; i++) {
    final diff = params.light[i] - params.dark[i];
    result[i] = diff < 0 ? 0 : diff;
  }

  return result;
}
