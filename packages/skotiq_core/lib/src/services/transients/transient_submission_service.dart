import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../database/database.dart' show TransientDetectionRow;
import '../logging_service.dart';
import 'transient_report_service.dart';

/// Outcome of a TNS bulk-report submission.
class TnsSubmissionResult {
  final bool success;

  /// The assigned IAU AT name (e.g. "AT2026xyz") when the report resolved to a
  /// named object, else null.
  final String? atName;

  /// The TNS-assigned report id returned by `set/bulk-report` (the queue id we
  /// poll on), else null.
  final String? reportId;

  /// Human-readable status / error surfaced to the UI.
  final String message;

  /// The raw decoded reply (for debugging / a "show details" affordance). May
  /// be null on a transport-level failure.
  final Map<String, dynamic>? rawReply;

  const TnsSubmissionResult({
    required this.success,
    this.atName,
    this.reportId,
    required this.message,
    this.rawReply,
  });

  factory TnsSubmissionResult.failure(
    String message, {
    Map<String, dynamic>? rawReply,
    String? reportId,
  }) => TnsSubmissionResult(
    success: false,
    message: message,
    rawReply: rawReply,
    reportId: reportId,
  );
}

/// Network/upload seam for First Light discovery reports.
///
/// Honest division of labour per catalog:
///   * AAVSO — export only. There is no per-observer authenticated REST upload;
///     the real path is a manual WebObs file upload. [exportAavso] writes the
///     ingestible .txt and returns its path.
///   * MPC — export only. ADES submission is via the MPC web form / email;
///     [exportMpcAdes] writes the .psv and returns its path.
///   * TNS — REAL submission. TNS exposes an authenticated bot REST API, so
///     [submitToTns] performs the genuine `set/bulk-report` POST and polls
///     `get/bulk-report-reply` for the assigned AT name.
///
/// Credentials are read by the caller (non-secret from ScienceSettings, the
/// secret api key from the keyring) and passed in via [TnsCredentials]; they
/// are never logged.
class TransientSubmissionService {
  final http.Client _http;
  final LoggingService _logger;
  final TransientReportService _reports;

  TransientSubmissionService({
    required http.Client httpClient,
    required LoggingService logger,
    TransientReportService? reportService,
  }) : _http = httpClient,
       _logger = logger,
       _reports = reportService ?? TransientReportService();

  static const String _prodBase = 'https://www.wis-tns.org/api';
  static const String _sandboxBase = 'https://sandbox.wis-tns.org/api';

  /// Write the ingestible AAVSO Extended File Format report and return its path.
  /// Export-only (manual WebObs upload is the real submission path).
  Future<String> exportAavso({
    required TransientDetectionRow detection,
    required String observerCode,
    required double magZeroPoint,
    String? starName,
    String? standardBand,
  }) async {
    final content = _reports.generateAavsoReport(
      detection: detection,
      observerCode: observerCode,
      magZeroPoint: magZeroPoint,
      starName: starName,
      standardBand: standardBand,
    );
    return _reports.writeReport(
      content: content,
      fileName: 'aavso_transient_${detection.id}_${_stamp()}.txt',
    );
  }

  /// Write the MPC ADES PSV report and return its path. Export-only (MPC web
  /// form / email submission is the real path).
  Future<String> exportMpcAdes({
    required TransientDetectionRow detection,
    required String observatoryCode,
    required String observerName,
    String? astrometricCatalog,
  }) async {
    final content = _reports.generateMpcAdesPsv(
      detection: detection,
      observatoryCode: observatoryCode,
      observerName: observerName,
      astrometricCatalog: astrometricCatalog,
    );
    return _reports.writeReport(
      content: content,
      fileName: 'mpc_ades_transient_${detection.id}_${_stamp()}.psv',
    );
  }

  /// REAL TNS submission: POST the bulk report, then poll for the reply.
  ///
  /// Production submits create a public AT record — the caller MUST gate this
  /// behind an explicit user confirm. Use [TnsCredentials.useSandbox] for tests.
  Future<TnsSubmissionResult> submitToTns({
    required TransientDetectionRow detection,
    required TnsCredentials creds,
  }) async {
    if (!creds.isComplete) {
      return TnsSubmissionResult.failure(
        'TNS credentials are incomplete — set the bot id/name/group/source, '
        'reporter, and api key in Settings > Science.',
      );
    }

    final base = creds.useSandbox ? _sandboxBase : _prodBase;
    final marker =
        'tns_marker'
        '{"tns_id":${creds.botId},"type":"bot",'
        '"name":"${creds.botName.replaceAll('"', r'\"')}"}';

    final reportJson = _reports.buildTnsReportJson(
      detection: detection,
      creds: creds,
    );

    String? reportId;
    try {
      final setResp = await _http.post(
        Uri.parse('$base/set/bulk-report'),
        headers: {'User-Agent': marker},
        body: {'api_key': creds.apiKey, 'data': jsonEncode(reportJson)},
      );
      final setDecoded = _tryDecode(setResp.body);
      if (setResp.statusCode != 200) {
        return TnsSubmissionResult.failure(
          'TNS set/bulk-report returned HTTP ${setResp.statusCode}: '
          '${_idMessage(setDecoded) ?? setResp.reasonPhrase ?? 'error'}',
          rawReply: setDecoded,
        );
      }
      reportId = _extractReportId(setDecoded);
      if (reportId == null) {
        return TnsSubmissionResult.failure(
          'TNS accepted the request but returned no report_id '
          '(${_idMessage(setDecoded) ?? 'unexpected response'}).',
          rawReply: setDecoded,
        );
      }
      _logger.info(
        'TNS bulk-report queued (report_id=$reportId, '
        'sandbox=${creds.useSandbox})',
        source: 'TransientSubmissionService',
      );
    } catch (e) {
      _logger.warning(
        'TNS set/bulk-report failed: $e',
        source: 'TransientSubmissionService',
      );
      return TnsSubmissionResult.failure('TNS submission failed: $e');
    }

    // Poll the asynchronous reply. The set call only queues the report.
    return _pollTnsReply(
      base: base,
      marker: marker,
      apiKey: creds.apiKey,
      reportId: reportId,
    );
  }

  Future<TnsSubmissionResult> _pollTnsReply({
    required String base,
    required String marker,
    required String apiKey,
    required String reportId,
    int maxAttempts = 10,
    Duration interval = const Duration(seconds: 3),
  }) async {
    Map<String, dynamic>? lastReply;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(interval);
      try {
        final resp = await _http.post(
          Uri.parse('$base/get/bulk-report-reply'),
          headers: {'User-Agent': marker},
          body: {'api_key': apiKey, 'report_id': reportId},
        );
        final decoded = _tryDecode(resp.body);
        lastReply = decoded;
        if (resp.statusCode == 404) {
          // Not processed yet — keep polling.
          continue;
        }
        if (resp.statusCode != 200) {
          continue;
        }
        final atName = _extractAtName(decoded);
        if (atName != null) {
          _logger.info(
            'TNS report $reportId resolved to $atName',
            source: 'TransientSubmissionService',
          );
          return TnsSubmissionResult(
            success: true,
            atName: atName,
            reportId: reportId,
            message: 'Submitted as $atName',
            rawReply: decoded,
          );
        }
        // A 200 with a processed-but-no-name reply: accepted, name pending.
        if (_isProcessed(decoded)) {
          return TnsSubmissionResult(
            success: true,
            reportId: reportId,
            message:
                'Submitted to TNS (report $reportId). The AT name will be '
                'assigned shortly — check the TNS report page.',
            rawReply: decoded,
          );
        }
      } catch (e) {
        _logger.warning(
          'TNS bulk-report-reply poll failed: $e',
          source: 'TransientSubmissionService',
        );
      }
    }
    return TnsSubmissionResult(
      success: true,
      reportId: reportId,
      message:
          'Submitted to TNS (report $reportId). Processing is still pending — '
          'check the TNS report page for the assigned AT name.',
      rawReply: lastReply,
    );
  }

  // ── reply parsing ──────────────────────────────────────────────────────────

  Map<String, dynamic>? _tryDecode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (e) {
      // Non-JSON body (e.g. an HTML error page). The caller treats a null
      // decode as "no structured reply"; log at debug so an unexpected
      // non-JSON TNS response is diagnosable instead of vanishing.
      _logger.debug(
        'TNS reply was not JSON; treating as unstructured: $e',
        source: 'TransientSubmissionService',
      );
    }
    return null;
  }

  String? _idMessage(Map<String, dynamic>? m) => m?['id_message']?.toString();

  String? _extractReportId(Map<String, dynamic>? m) {
    final data = m?['data'];
    if (data is Map) {
      final id = data['report_id'];
      if (id != null) return id.toString();
    }
    return null;
  }

  bool _isProcessed(Map<String, dynamic>? m) {
    // TNS uses id_code 200 / "OK" on a completed reply.
    final code = m?['id_code'];
    if (code is int) return code == 200;
    if (code is String) return code == '200';
    return false;
  }

  /// Walk the bulk-report-reply structure for an assigned AT name. The reply
  /// nests per-report feedback; the object name surfaces under a `100`/`101`
  /// feedback entry. We search recursively for any string matching `AT\d{4}...`.
  String? _extractAtName(Map<String, dynamic>? m) {
    if (m == null) return null;
    final found = <String>[];
    void walk(dynamic node) {
      if (node is Map) {
        for (final v in node.values) {
          walk(v);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      } else if (node is String) {
        final match = RegExp(r'\bAT\d{4}[a-zA-Z]+\b').firstMatch(node);
        if (match != null) found.add(match.group(0)!);
      }
    }

    walk(m);
    return found.isEmpty ? null : found.first;
  }

  String _stamp() => DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;
}
