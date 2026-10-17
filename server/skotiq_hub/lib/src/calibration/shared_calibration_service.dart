import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../auth/account_service.dart';
import '../auth/token_service.dart';
import '../db/hub_database.dart';
import 'calibration_master_store.dart';
import 'fits_master_validation.dart';

/// Ledger + storage orchestration for the shared calibration library's
/// master artifacts.
///
/// Darks (and biases) are a pure function of the sensor + capture tuple
/// (camera, gain, offset, exposure, binning, temperature) and are the safest
/// thing to share. Flats are optics-specific: a flat is only ever valid on the
/// exact optical train that produced it, so a shared flat MUST carry an
/// `optical_train` tag and the matcher (client + hub) never reuses one across
/// trains. Defect maps and any unknown type are not shareable.
///
/// Every publish is consent-gated: the `license` must be an explicit shareable
/// `ContributionLicense` (never the fail-closed `private`), and the
/// self-reported identity in `provenance_json` is overwritten with the
/// AUTHENTICATED principal via [stampAuthoritativeProvenanceIdentity] before it
/// is stored, so the `account_id` column (and only it) is the trustworthy
/// "who shot this" key.
class SharedCalibrationService {
  SharedCalibrationService({
    required HubDatabase db,
    required CalibrationMasterStore store,
    required AccountService accounts,
  }) : _db = db,
       _store = store,
       _accounts = accounts;

  final HubDatabase _db;
  final CalibrationMasterStore _store;
  final AccountService _accounts;
  final Uuid _uuid = const Uuid();

  /// The master types that may be shared. Defect maps are camera-firmware /
  /// build specific and flats are gated additionally on an optical-train tag.
  static const Set<String> shareableTypes = {'dark', 'bias', 'flat'};

  /// The shareable licenses a publish may declare. `private` is the fail-closed
  /// default and is NOT a publishable choice — every share records an explicit
  /// consented, shareable license. Mirrors the table's CHECK + the client
  /// `ContributionLicense` wire names.
  static const Set<String> shareableLicenses = {
    'cc0',
    'cc-by',
    'cc-by-sa',
    'cc-by-nc',
  };

  /// Ceiling applied to the untrusted `frame_count` hint when it orders query
  /// results. A master built from this many frames is already excellent; clamping
  /// here means a forged `NFRAMES=999999` cannot outrank a genuine deep master —
  /// it only ties into the same top bucket, where recency + the client's quality
  /// gate decide. See [query].
  static const int _frameCountRankCap = 256;

  /// Publish one master for [accountId]. Stores the file, stamps authoritative
  /// provenance, and records the ledger row. Throws [CalibrationPublishRejected]
  /// when the share violates a quality/consent gate — a benign malformed request
  /// (mapped to 400 by the handler) or a `contentIntegrity` poison rejection
  /// (mapped to 422 so it feeds the abuse auto-flag).
  SharedCalibrationMasterRow publish({
    required String accountId,
    required String masterType,
    required String cameraModel,
    required String license,
    required Uint8List bytes,
    int sensorWidth = 0,
    int sensorHeight = 0,
    int gain = 0,
    int offset = 0,
    double exposureSeconds = 0,
    double? temperatureC,
    int binX = 1,
    int binY = 1,
    String? filter,
    String? opticalTrain,
    int frameCount = 0,
    double? darkCurrent,
    String? provenanceJson,
  }) {
    final type = masterType.trim();
    if (!shareableTypes.contains(type)) {
      throw CalibrationPublishRejected(
        'unsharableType',
        'master type "$masterType" cannot be shared '
            '(only ${shareableTypes.join(', ')})',
      );
    }
    if (!shareableLicenses.contains(license.trim())) {
      throw CalibrationPublishRejected(
        'unsharableLicense',
        'license "$license" is not a shareable license — publishing requires '
            'an explicit consented license (${shareableLicenses.join(', ')})',
      );
    }
    final camera = cameraModel.trim();
    if (camera.isEmpty) {
      throw CalibrationPublishRejected(
        'missingCamera',
        'a shared master must record its camera/sensor model',
      );
    }
    // Flats are optics-specific: never sharable without the optical-train tag
    // that scopes their reuse to the exact train that produced them.
    final train = opticalTrain?.trim();
    if (type == 'flat' && (train == null || train.isEmpty)) {
      throw CalibrationPublishRejected(
        'flatNoOpticalTrain',
        'a shared flat must carry an optical-train tag — flats are never '
            'reusable across optical trains',
      );
    }
    if (bytes.isEmpty) {
      throw CalibrationPublishRejected('emptyMaster', 'empty master body');
    }
    // The sensor geometry is the single hardest safety claim here: it drives the
    // client matcher's "different sensor can never calibrate this frame" gate.
    // Refuse a publish that omits it (a 0/unset dimension would otherwise match
    // ANY sensor on the puller's side).
    if (sensorWidth <= 0 || sensorHeight <= 0) {
      throw CalibrationPublishRejected(
        'missingDimensions',
        'a shared master must declare its sensor dimensions '
            '(sensorWidth/sensorHeight > 0)',
      );
    }
    // Do not trust the declared geometry: parse the real FITS bytes, require the
    // declared dimensions to equal the image axes, AND require the file to carry
    // a full pixel-data section sized for that geometry (FitsMasterHeader.parse).
    // The data-length check is what makes the geometry gate meaningful — without
    // it a ~3 KB header-only file could advertise a victim sensor's exact axes.
    final FitsMasterHeader header;
    try {
      header = FitsMasterHeader.parse(bytes);
    } on FitsValidationError catch (e) {
      throw CalibrationPublishRejected(
        e.code,
        e.message,
        contentIntegrity: true,
      );
    }
    if (header.naxis1 != sensorWidth || header.naxis2 != sensorHeight) {
      throw CalibrationPublishRejected(
        'dimensionMismatch',
        'declared sensor dimensions (${sensorWidth}x$sensorHeight) do not '
            'match the master FITS image axes '
            '(${header.naxis1}x${header.naxis2})',
        contentIntegrity: true,
      );
    }
    // Statistical sanity gate on the pixel data: reject an all-zero /
    // all-saturated / otherwise degenerate buffer that is structurally present
    // but carries no calibration signal (a poison master that would still rank).
    try {
      header.validatePixelSanity(bytes);
    } on FitsValidationError catch (e) {
      throw CalibrationPublishRejected(
        e.code,
        e.message,
        contentIntegrity: true,
      );
    }
    // NFRAMES is an UNTRUSTED hint, not authoritative — it is uploader-written
    // header text, equally forgeable to the `frameCount` query param. Prefer it
    // over the client param only as a tie-break signal; its influence on ranking
    // is capped in query() so it cannot float a poison master to the top.
    final resolvedFrameCount = header.frameCount ?? frameCount;

    final normalizedTrain = (train == null || train.isEmpty) ? null : train;
    final id = _uuid.v4();
    final stampedProvenance = stampAuthoritativeProvenanceIdentity(
      provenanceJson,
      accountId: accountId,
      authoritativeDisplayName: _accounts.getById(accountId)?.displayName,
    );
    final path = _store.save(accountId: accountId, masterId: id, bytes: bytes);
    final createdAt = DateTime.now().toUtc().toIso8601String();
    _db.db.execute(
      'INSERT INTO shared_calibration_masters '
      '(id, account_id, master_type, camera_model, sensor_width, '
      'sensor_height, gain, offset_value, exposure_seconds, temperature_c, '
      'bin_x, bin_y, filter, optical_train, frame_count, dark_current, '
      'license, provenance_json, path, bytes, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        id,
        accountId,
        type,
        camera,
        sensorWidth,
        sensorHeight,
        gain,
        offset,
        exposureSeconds,
        temperatureC,
        binX,
        binY,
        (filter == null || filter.trim().isEmpty) ? null : filter.trim(),
        normalizedTrain,
        resolvedFrameCount,
        darkCurrent,
        license.trim(),
        stampedProvenance,
        path,
        bytes.length,
        createdAt,
      ],
    );
    return _rowById(id)!;
  }

  /// Ranked remote candidates for a sensor + capture tuple. The hub does the
  /// coarse sensor-keyed filter (exact camera / gain / offset / binning, and
  /// only shareable licenses); the CLIENT applies the full per-type score +
  /// quality gate (exposure tolerance for darks, filter + optical-train for
  /// flats, sensor-dimension refusal) over the returned set.
  ///
  /// FLATS are scoped to the SAME OWNER ([requesterAccountId]): a flat encodes
  /// dust/vignetting unique to one physical optical train, and `optical_train` is
  /// a free-text, non-namespaced tag, so two unrelated members who both default
  /// their train to a common string ("Main", "OTA1", …) must never pull each
  /// other's flats. Darks/biases are a pure function of the sensor tuple and stay
  /// shareable across accounts.
  ///
  /// Ordered by a CAPPED provenance-strength bucket then recency. Frame count is
  /// an untrusted, uploader-forgeable hint (see [publish]); ranking by it
  /// uncapped would let a poison master declaring `NFRAMES=999999` float above
  /// every legitimate master. So it is clamped to [_frameCountRankCap] before it
  /// orders rows: a deep master still outranks a shallow one up to a sane bound,
  /// but an inflated value lands in the same top bucket as a genuinely
  /// well-supported master (recency then breaks the tie, and the client's own
  /// quality gate re-scores from server-observed signals).
  List<SharedCalibrationMasterRow> query({
    String? masterType,
    String? cameraModel,
    int? gain,
    int? offset,
    int? binX,
    int? binY,
    String? requesterAccountId,
    int limit = 50,
  }) {
    final clauses = <String>["license != 'private'"];
    final args = <Object?>[];
    final type = masterType?.trim();
    if (type != null && type.isNotEmpty) {
      clauses.add('master_type = ?');
      args.add(type);
    }
    // Cross-account flat reuse is forbidden (free-text train names are not
    // globally unique). When the caller's identity is known, restrict flats to
    // their own account; when it is unknown, exclude flats entirely rather than
    // risk a cross-train pull.
    final requester = requesterAccountId?.trim();
    if (requester != null && requester.isNotEmpty) {
      clauses.add("(master_type != 'flat' OR account_id = ?)");
      args.add(requester);
    } else {
      clauses.add("master_type != 'flat'");
    }
    final camera = cameraModel?.trim();
    if (camera != null && camera.isNotEmpty) {
      clauses.add('camera_model = ?');
      args.add(camera);
    }
    if (gain != null) {
      clauses.add('gain = ?');
      args.add(gain);
    }
    if (offset != null) {
      clauses.add('offset_value = ?');
      args.add(offset);
    }
    if (binX != null) {
      clauses.add('bin_x = ?');
      args.add(binX);
    }
    if (binY != null) {
      clauses.add('bin_y = ?');
      args.add(binY);
    }
    final cappedLimit = limit < 1 ? 1 : (limit > 200 ? 200 : limit);
    final rows = _db.db.select(
      'SELECT * FROM shared_calibration_masters WHERE ${clauses.join(' AND ')} '
      'ORDER BY MIN(frame_count, $_frameCountRankCap) DESC, created_at DESC '
      'LIMIT $cappedLimit;',
      args,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// One master row by id, or null.
  SharedCalibrationMasterRow? get(String id) => _rowById(id);

  /// The stored bytes for a master, or null when the file is gone.
  Uint8List? bytesFor(SharedCalibrationMasterRow row) => _store.load(row.path);

  /// Delete a published master (file + row). [requesterId] non-null scopes the
  /// delete to the owner; null (admin) may delete anyone's. Throws
  /// [CalibrationMasterNotFound] / [CalibrationMasterForbidden].
  void delete(String id, {String? requesterId}) {
    final row = _rowById(id);
    if (row == null) throw CalibrationMasterNotFound(id);
    if (requesterId != null && requesterId != row.accountId) {
      throw CalibrationMasterForbidden(id);
    }
    _store.delete(row.path);
    _db.db.execute(
      'DELETE FROM shared_calibration_masters WHERE id = ?;',
      <Object?>[id],
    );
  }

  SharedCalibrationMasterRow? _rowById(String id) {
    final rows = _db.db.select(
      'SELECT * FROM shared_calibration_masters WHERE id = ?;',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  SharedCalibrationMasterRow _fromRow(dynamic row) {
    return SharedCalibrationMasterRow(
      id: row['id'] as String,
      accountId: row['account_id'] as String,
      masterType: row['master_type'] as String,
      cameraModel: row['camera_model'] as String,
      sensorWidth: (row['sensor_width'] as num?)?.toInt() ?? 0,
      sensorHeight: (row['sensor_height'] as num?)?.toInt() ?? 0,
      gain: (row['gain'] as num?)?.toInt() ?? 0,
      offset: (row['offset_value'] as num?)?.toInt() ?? 0,
      exposureSeconds: (row['exposure_seconds'] as num?)?.toDouble() ?? 0.0,
      temperatureC: (row['temperature_c'] as num?)?.toDouble(),
      binX: (row['bin_x'] as num?)?.toInt() ?? 1,
      binY: (row['bin_y'] as num?)?.toInt() ?? 1,
      filter: row['filter'] as String?,
      opticalTrain: row['optical_train'] as String?,
      frameCount: (row['frame_count'] as num?)?.toInt() ?? 0,
      darkCurrent: (row['dark_current'] as num?)?.toDouble(),
      license: row['license'] as String,
      provenanceJson: row['provenance_json'] as String? ?? '{}',
      path: row['path'] as String,
      bytes: (row['bytes'] as num?)?.toInt() ?? 0,
      createdAt: row['created_at'] as String,
    );
  }
}

/// One published shared-calibration-master row. [toJson] is the wire shape the
/// client's `SharedCalibrationMaster.fromJson` decodes (camelCase, with the
/// authoritative `accountId` as the trustworthy producer identity).
class SharedCalibrationMasterRow {
  const SharedCalibrationMasterRow({
    required this.id,
    required this.accountId,
    required this.masterType,
    required this.cameraModel,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.gain,
    required this.offset,
    required this.exposureSeconds,
    required this.temperatureC,
    required this.binX,
    required this.binY,
    required this.filter,
    required this.opticalTrain,
    required this.frameCount,
    required this.darkCurrent,
    required this.license,
    required this.provenanceJson,
    required this.path,
    required this.bytes,
    required this.createdAt,
  });

  final String id;
  final String accountId;
  final String masterType;
  final String cameraModel;
  final int sensorWidth;
  final int sensorHeight;
  final int gain;
  final int offset;
  final double exposureSeconds;
  final double? temperatureC;
  final int binX;
  final int binY;
  final String? filter;
  final String? opticalTrain;
  final int frameCount;
  final double? darkCurrent;
  final String license;
  final String provenanceJson;
  final String path;
  final int bytes;
  final String createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'accountId': accountId,
    'masterType': masterType,
    'cameraModel': cameraModel,
    'sensorWidth': sensorWidth,
    'sensorHeight': sensorHeight,
    'gain': gain,
    'offset': offset,
    'exposureSeconds': exposureSeconds,
    if (temperatureC != null) 'temperatureC': temperatureC,
    'binX': binX,
    'binY': binY,
    if (filter != null) 'filter': filter,
    if (opticalTrain != null) 'opticalTrain': opticalTrain,
    'frameCount': frameCount,
    if (darkCurrent != null) 'darkCurrent': darkCurrent,
    'license': license,
    'provenanceJson': provenanceJson,
    'bytes': bytes,
    'createdAt': createdAt,
  };
}

/// A publish that violates a quality/consent gate.
///
/// A benign bad-request gate (unsharable type/license, missing camera, a flat
/// with no optical train, missing/empty declaration) maps to HTTP 400 — an
/// honest-but-malformed request that must not accrue against the abuse
/// auto-flag. A [contentIntegrity] rejection is the poison-flood case instead:
/// bytes that FAIL FITS validation (parse/geometry/pixel-sanity) or a declared
/// geometry that does not match the real image axes — a crafted master spoofing
/// a victim sensor. Those map to HTTP 422 so `_auditDenialMiddleware` counts
/// them toward `checkAbuse`, exactly like the co-imaging implausible-report 422
/// and the tile-fusion soft-reject `checkAbuse`.
class CalibrationPublishRejected implements Exception {
  CalibrationPublishRejected(
    this.code,
    this.message, {
    this.contentIntegrity = false,
  });
  final String code;
  final String message;

  /// True when the rejection is a content-integrity failure (poison bytes /
  /// spoofed geometry) rather than a benign malformed request — the handler
  /// maps these to 422 so they feed the abuse auto-suspend.
  final bool contentIntegrity;

  @override
  String toString() => 'CalibrationPublishRejected($code): $message';
}

/// No shared master with the given id exists.
class CalibrationMasterNotFound implements Exception {
  CalibrationMasterNotFound(this.id);
  final String id;
}

/// The requester does not own the shared master they tried to delete.
class CalibrationMasterForbidden implements Exception {
  CalibrationMasterForbidden(this.id);
  final String id;
}
