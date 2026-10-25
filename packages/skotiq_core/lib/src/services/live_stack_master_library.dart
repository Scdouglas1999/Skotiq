/// Saving a live stack as a master the rest of the app can find.
///
/// A live stack's FITS master is a linear integration like any other, so it is
/// registered in the master library: the Darkroom lists it under its target and
/// opens it in the editor. A PNG save is a picture of the render, not a master,
/// and is not registered.
library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import '../database/daos/integrated_masters_dao.dart';
import '../models/imaging/integrated_master.dart';
import 'calibration/fits_header_reader.dart';
import 'darkroom_build_service.dart' show DarkroomHeaderReader;
import 'live_stacking_service.dart';

/// Writes a stretched PNG of [result] to [path].
typedef LiveStackPreviewWriter =
    Future<void> Function(String path, LiveStackingResult result);

/// What a library save wrote.
class LiveStackLibrarySave {
  /// The file the stacker wrote.
  final LiveStackingMasterSave saved;

  /// The library row, or null when the save was not a FITS master.
  final int? masterId;

  /// The thumbnail beside the master, or null when it could not be written.
  final String? previewPath;

  const LiveStackLibrarySave({
    required this.saved,
    required this.masterId,
    required this.previewPath,
  });
}

/// Saves the live stack and registers its FITS master.
class LiveStackMasterLibrary {
  final Future<LiveStackingResult> Function() _currentResult;
  final Future<LiveStackingMasterSave> Function(String filePath) _saveMaster;
  final LiveStackPreviewWriter _writePreview;
  final IntegratedMastersDao _masters;
  final DarkroomHeaderReader _readHeader;

  LiveStackMasterLibrary({
    required Future<LiveStackingResult> Function() currentResult,
    required Future<LiveStackingMasterSave> Function(String filePath)
    saveMaster,
    required LiveStackPreviewWriter writePreview,
    required IntegratedMastersDao masters,
    DarkroomHeaderReader? readHeader,
  }) : _currentResult = currentResult,
       _saveMaster = saveMaster,
       _writePreview = writePreview,
       _masters = masters,
       _readHeader =
           readHeader ??
           ((path) => const FitsHeaderReader().readPrimaryHeader(path));

  /// Write the stack to [filePath] and, for a FITS master, register it with a
  /// stretched thumbnail beside it.
  ///
  /// The stack is read before the file is written, so this is safe to call
  /// right before the stacker is stopped. A thumbnail or header that cannot be
  /// produced leaves the row without that detail; the master is still
  /// registered, because the FITS file is what the library is for.
  ///
  /// The stacked master's header carries no `OBJECT` or `FILTER`, so the
  /// target and filter are read from [sourceFramePath], a frame of the stack
  /// (its reference), when the master names none.
  Future<LiveStackLibrarySave> save(
    String filePath, {
    String? sourceFramePath,
  }) async {
    final result = await _currentResult();
    final saved = await _saveMaster(filePath);
    if (saved.format != LiveStackingMasterFormat.fitsMaster) {
      return LiveStackLibrarySave(
        saved: saved,
        masterId: null,
        previewPath: null,
      );
    }
    String? preview = p.setExtension(saved.filePath, '.png');
    try {
      await _writePreview(preview, result);
    } catch (error) {
      developer.log(
        'Live stack: the thumbnail for ${saved.filePath} was not written: '
        '$error',
        name: 'LiveStackMasterLibrary',
        level: 900,
      );
      preview = null;
    }
    final header = <String, String>{};
    for (final path in [?sourceFramePath, saved.filePath]) {
      try {
        header.addAll(await _readHeader(path));
      } catch (error) {
        developer.log(
          'Live stack: the header of $path could not be read, so the master '
          'may name no target or filter: $error',
          name: 'LiveStackMasterLibrary',
          level: 900,
        );
      }
    }
    final object = FitsHeaderReader.stringValue(header, 'OBJECT')?.trim();
    final filter = FitsHeaderReader.stringValue(header, 'FILTER')?.trim();
    final target = object == null || object.isEmpty ? null : object;
    final band = filter == null || filter.isEmpty ? null : filter;
    final name = [
      target ?? 'Live stack',
      if (band != null) band,
      if (target != null) 'live stack',
    ].join(' ');
    final id = await _masters.insertMaster(
      name: name,
      masterFitsPath: saved.filePath,
      previewPngPath: preview,
      filter: band,
      channels: result.channels,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.runningWeightedMean,
      width: result.width,
      height: result.height,
      frameCount: saved.stackedFrameCount,
      totalIntegrationSeconds: saved.totalIntegrationSecs ?? 0,
      settingsJson: jsonEncode({
        'source': 'liveStack',
        if (target != null) 'target': target,
      }),
      statsJson: jsonEncode({
        if (saved.dateObs != null) 'dateObs': saved.dateObs,
      }),
    );
    return LiveStackLibrarySave(
      saved: saved,
      masterId: id,
      previewPath: preview,
    );
  }
}

final liveStackMasterLibraryProvider = Provider<LiveStackMasterLibrary>((ref) {
  final stacking = ref.watch(liveStackingServiceProvider);
  return LiveStackMasterLibrary(
    currentResult: stacking.getCurrentResult,
    saveMaster: (path) => stacking.saveMaster(filePath: path),
    writePreview: (path, result) => bridge.apiSaveRgbaPngFile(
      filePath: path,
      width: result.width,
      height: result.height,
      rgba: stacking.autoStretchPreview(
        width: result.width,
        height: result.height,
        data: result.data,
        channels: result.channels,
      ),
    ),
    masters: ref.watch(integratedMastersDaoProvider),
  );
});
