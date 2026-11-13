import '../../services/observation_report_service.dart';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

enum SessionExportFormat { json, csv, html }

/// The files and products the Analytics screen has the imaging host make from
/// its sessions. Each one ends as a file on this machine or as rows in the
/// host's database.
abstract interface class AnalyticsExports {
  /// Writes one session's data and returns the file.
  Future<String> sessionExport(int sessionId, SessionExportFormat format);

  /// Writes the session's AAVSO extended file for [targetStarName].
  Future<String> aavsoExport(int sessionId, String targetStarName);

  /// Writes the session's observation report. A report a linked host
  /// generated is saved into [directory], asked for once the report is here.
  Future<String> observationReport(
    int sessionId,
    Future<Directory> Function() directory,
  );

  /// Writes the Science tab's report of the session. [period] is the period
  /// search on screen, which is never stored.
  Future<File> scienceReport(int sessionId, {PeriodAnalysisResult? period});

  /// Makes the session's narrowband line ratios from its newest H-alpha, OIII
  /// and SII frames and returns the sentence that says what happened.
  Future<String> generateLineRatios(int sessionId);
}

final analyticsExportsProvider = hostRoleProvider<AnalyticsExports>(
  here: _LocalAnalyticsExports.new,
  linked: _HostAnalyticsExports.new,
);

final class _LocalAnalyticsExports implements AnalyticsExports {
  _LocalAnalyticsExports(this._ref);

  final Ref _ref;

  @override
  Future<String> sessionExport(int sessionId, SessionExportFormat format) {
    final service = SessionExportService(
      sessionsDao: _ref.read(sessionsDaoProvider),
      imagesDao: _ref.read(imagesDaoProvider),
      nowProvider: _ref.read(clockProvider).now,
    );
    return switch (format) {
      SessionExportFormat.json => service.exportToJson(sessionId),
      SessionExportFormat.csv => service.exportToCsv(sessionId),
      SessionExportFormat.html => service.exportToHtml(sessionId),
    };
  }

  @override
  Future<String> aavsoExport(int sessionId, String targetStarName) =>
      AavsoExportService(
        scienceDao: _ref.read(scienceDaoProvider),
        settingsDao: _ref.read(settingsDaoProvider),
        imagesDao: _ref.read(imagesDaoProvider),
        softwareLabel: _ref.read(appVersionLabelProvider),
      ).exportSession(sessionId: sessionId, targetStarName: targetStarName);

  @override
  Future<String> observationReport(
    int sessionId,
    Future<Directory> Function() directory,
  ) =>
      ObservationReportService(
        sessionsDao: _ref.read(sessionsDaoProvider),
        imagesDao: _ref.read(imagesDaoProvider),
        scienceDao: _ref.read(scienceDaoProvider),
      ).generateReport(sessionId: sessionId);

  @override
  Future<File> scienceReport(int sessionId, {PeriodAnalysisResult? period}) =>
      _ref
          .read(scienceReportExporterProvider)
          .exportToDisk(sessionId, period: period);

  @override
  Future<String> generateLineRatios(int sessionId) async {
    final images = await _ref
        .read(imagesDaoProvider)
        .getImagesForSession(sessionId);
    final ha = _latestByFilter(images, {
      'ha',
      'halpha',
      'h-alpha',
      'h alpha',
    });
    final oiii = _latestByFilter(images, {'oiii', 'o3'});
    final sii = _latestByFilter(images, {'sii', 's2'});
    if (ha == null || oiii == null || sii == null) {
      return 'Need latest H-alpha, OIII, and SII frames in this session.';
    }
    await _ref
        .read(scienceProcessingServiceProvider)
        .generateLineRatios(
          sessionId: sessionId,
          set: NarrowbandSet(
            hAlphaPath: ha.filePath,
            oiiiPath: oiii.filePath,
            siiPath: sii.filePath,
          ),
          hAlphaImageId: ha.id,
          oiiiImageId: oiii.id,
          siiImageId: sii.id,
        );
    return 'Generated using ${ha.fileName}, ${oiii.fileName}, ${sii.fileName}.';
  }
}

/// A linked host makes each product from its own frames; the files it sends
/// back are saved in this machine's exports folder.
final class _HostAnalyticsExports implements AnalyticsExports {
  _HostAnalyticsExports(this._ref, this._host);

  final Ref _ref;
  final RemoteHost _host;

  @override
  Future<String> sessionExport(
    int sessionId,
    SessionExportFormat format,
  ) async {
    final bytes = await _host.files.downloadSessionExport(
      sessionId,
      format.name,
    );
    return _saveExport(
      'session_${sessionId}_${DateTime.now().millisecondsSinceEpoch}'
      '.${format.name}',
      bytes,
    );
  }

  @override
  Future<String> aavsoExport(int sessionId, String targetStarName) async {
    final bytes = await _host.science.exportSessionAavso(
      sessionId,
      targetStarName: targetStarName,
    );
    return _saveExport(
      'AAVSO_${targetStarName.replaceAll(' ', '_')}_'
      '${DateTime.now().millisecondsSinceEpoch}.txt',
      bytes,
    );
  }

  @override
  Future<String> observationReport(
    int sessionId,
    Future<Directory> Function() directory,
  ) async {
    final bytes = await _host.science.generateObservationReport(sessionId);
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final filePath = path.join(
      (await directory()).path,
      'observation_report_${timestamp}Z.pdf',
    );
    await File(filePath).writeAsBytes(bytes, flush: true);
    return filePath;
  }

  @override
  Future<File> scienceReport(int sessionId, {PeriodAnalysisResult? period}) =>
      saveHostScienceReport(_host.science, sessionId);

  @override
  Future<String> generateLineRatios(int sessionId) async {
    final result = await _host.science.generateSessionLineRatios(sessionId);
    _ref.invalidate(sessionLineRatioProductsProvider(sessionId));
    final files = (result['files'] as List?)?.join(', ') ?? 'host frames';
    return 'Generated using $files.';
  }

  Future<String> _saveExport(String fileName, List<int> bytes) async {
    final directory = await resolveSkotiqExportsDirectory();
    final filePath = path.join(directory.path, fileName);
    await File(filePath).writeAsBytes(bytes, flush: true);
    return filePath;
  }
}

/// Saves the report PDF a linked host generates for the session into this
/// machine's exports folder.
Future<File> saveHostScienceReport(
  HostScience host,
  int sessionId, {
  Future<Directory> Function()? documentsDirectoryProvider,
  DateTime? generatedAt,
}) async {
  final bytes = await host.generateObservationReport(sessionId);
  if (bytes.isEmpty) {
    throw StateError('The imaging host returned an empty science report.');
  }
  final exportDirectory = await resolveSkotiqExportsDirectory(
    documents: documentsDirectoryProvider ?? resolveSkotiqDocumentsDirectory,
  );
  final timestamp = (generatedAt ?? DateTime.now())
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;
  final file = File(
    path.join(
      exportDirectory.path,
      'science_report_session_${sessionId}_$timestamp.pdf',
    ),
  );
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

DbCapturedImage? _latestByFilter(
  List<DbCapturedImage> images,
  Set<String> names,
) {
  DbCapturedImage? latest;
  for (final image in images) {
    final filter = (image.filter ?? '').toLowerCase().trim();
    // The name alone or as a whole word, so "Shah" is not H-alpha.
    final named = names.any(
      (name) =>
          filter == name ||
          RegExp(
            '(?:^|[\\s_-])${RegExp.escape(name)}(?:[\\s_-]|\$)',
          ).hasMatch(filter),
    );
    if (!named) continue;
    if (latest == null || image.capturedAt.isAfter(latest.capturedAt)) {
      latest = image;
    }
  }
  return latest;
}

/// Reports of one transient detection: the files for AAVSO and the MPC, and
/// the submission to the TNS, made by whichever machine holds the detection
/// and the credentials.
abstract interface class TransientReports {
  Future<String> exportAavso(
    TransientDetectionRow detection,
    ScienceSettings settings, {
    required double magZeroPoint,
  });

  Future<String> exportMpcAdes(
    TransientDetectionRow detection,
    ScienceSettings settings,
  );

  Future<TnsSubmissionResult> submitToTns(
    TransientDetectionRow detection,
    ScienceSettings settings,
  );
}

final transientReportsProvider = hostRoleProvider<TransientReports>(
  here: _LocalTransientReports.new,
  linked: _HostTransientReports.new,
);

final class _LocalTransientReports implements TransientReports {
  _LocalTransientReports(this._ref);

  final Ref _ref;

  @override
  Future<String> exportAavso(
    TransientDetectionRow detection,
    ScienceSettings settings, {
    required double magZeroPoint,
  }) => _ref
      .read(transientSubmissionServiceProvider)
      .exportAavso(
        detection: detection,
        observerCode: settings.aavsoObserverCode,
        magZeroPoint: magZeroPoint,
      );

  @override
  Future<String> exportMpcAdes(
    TransientDetectionRow detection,
    ScienceSettings settings,
  ) => _ref
      .read(transientSubmissionServiceProvider)
      .exportMpcAdes(
        detection: detection,
        observatoryCode: settings.mpcObservatoryCode,
        observerName: settings.observerName,
        astrometricCatalog: settings.mpcAstrometricCatalog,
      );

  @override
  Future<TnsSubmissionResult> submitToTns(
    TransientDetectionRow detection,
    ScienceSettings settings,
  ) async {
    final apiKey = await _ref
        .read(secretsStoreProvider)
        .read(SecretField.tnsApiKey);
    return _ref
        .read(transientSubmissionServiceProvider)
        .submitToTns(
          detection: detection,
          creds: TnsCredentials(
            botId: settings.tnsBotId,
            botName: settings.tnsBotName,
            reportingGroupId: settings.tnsReportingGroupId,
            dataSourceId: settings.tnsDataSourceId,
            reporterName: settings.tnsReporterName.isNotEmpty
                ? settings.tnsReporterName
                : settings.observerName,
            apiKey: apiKey,
            useSandbox: settings.tnsUseSandbox,
          ),
        );
  }
}

/// A linked host holds the detection, the observer codes and the TNS key, so
/// it builds each report; this machine only saves the file.
final class _HostTransientReports implements TransientReports {
  _HostTransientReports(this._ref, this._host);

  final Ref _ref;
  final RemoteHost _host;
  final _files = TransientReportService();

  @override
  Future<String> exportAavso(
    TransientDetectionRow detection,
    ScienceSettings settings, {
    required double magZeroPoint,
  }) async => _files.writeReport(
    content: String.fromCharCodes(
      await _host.transients.exportFirstLightAavso(
        detection.id,
        magZeroPoint: magZeroPoint,
      ),
    ),
    fileName: 'aavso_transient_${detection.id}.txt',
  );

  @override
  Future<String> exportMpcAdes(
    TransientDetectionRow detection,
    ScienceSettings settings,
  ) async => _files.writeReport(
    content: String.fromCharCodes(
      await _host.transients.exportFirstLightMpc(detection.id),
    ),
    fileName: 'mpc_ades_transient_${detection.id}.psv',
  );

  @override
  Future<TnsSubmissionResult> submitToTns(
    TransientDetectionRow detection,
    ScienceSettings settings,
  ) async {
    final result = await _host.transients.submitFirstLightToTns(detection.id);
    final success = result['success'] == true;
    // The host marked the detection reviewed; show that here too.
    if (success) _ref.invalidate(firstLightCandidatesProvider);
    return TnsSubmissionResult(
      success: success,
      atName: result['atName'] as String?,
      message: result['message']?.toString() ?? 'TNS submission done',
    );
  }
}
