/// Pure-Dart reader/writer/merger for the Skotiq sky-atlas tile sidecar
/// (`.skt`), bit-compatible with `native/.../imaging/src/sky_atlas.rs`.
///
/// # Why this lives in the hub
///
/// The hub fuses contributions server-side, which it can do either by calling
/// the Rust `merge_tiles` over an FFI shim or by re-implementing the documented
/// additive merge in Dart. The
/// keystone's on-disk format is `SKT1` (`TILE_MAGIC` / `TILE_STATE_VERSION = 1`),
/// and the federation algebra is deliberately trivial: a per-pixel weighted
/// mean decomposes into six running vectors (`sum_w`, `sum_w2`, `sum_wx`,
/// `sum_wx2`, `coverage`, `rejected`) that are **exactly additive across
/// disjoint contributors**. Merging two contributors is element-wise addition of
/// those vectors (the weighted sums scaled by the contributor's trust), plus a
/// provenance union. Re-implementing exactly that in Dart keeps the hub a single
/// self-hostable Dart runtime with no native build step, while staying
/// bit-for-bit identical to the keystone for `clip == None`.
///
/// # On-disk layout (mirrors `SkyTileAccumulator::serialize`)
///
/// ```text
/// MAGIC "SKT1" (4) | version u32 LE | header_len u32 LE | JSON header |
/// payload: sum_w[len] f64 | sum_w2[len] f64 | sum_wx[len] f64 |
///          sum_wx2[len] f64 | coverage[len] u32 | rejected[len] u32   (all LE)
/// ```
///
/// The JSON header uses serde's default (snake_case) field names because the
/// Rust structs carry no `#[serde(rename_all)]`. We round-trip the header
/// verbatim (`Map<String, Object?>`) so any keys we do not interpret survive a
/// merge unchanged — the hub never silently drops keystone provenance.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Magic bytes prefixing a serialized tile sidecar. Matches
/// `sky_atlas.rs::TILE_MAGIC`.
const List<int> tileMagic = <int>[0x53, 0x4B, 0x54, 0x31]; // "SKT1"

/// Magic on sidecars serialized before the rebrand. Matches
/// `sky_atlas.rs::LEGACY_TILE_MAGIC`; accepted on decode so atlases and
/// deltas emitted by older builds keep loading.
const List<int> legacyTileMagic = <int>[0x4E, 0x53, 0x54, 0x31]; // "NST1"

/// On-disk format version this build reads/writes. Matches
/// `sky_atlas.rs::TILE_STATE_VERSION`.
const int tileStateVersion = 1;

const int _fixedPrefixBytes = 12; // 4 magic + 4 version + 4 header_len

/// Thrown when a `.skt` blob is malformed, the wrong version, or two operands
/// cannot be merged (geometry / order / channel / id mismatch).
///
/// The HTTP layer maps [code] to a status: `geometryMismatch` / `orderMismatch`
/// / `channelMismatch` / `idMismatch` → 409 Conflict; everything else → 400.
class TileCodecException implements Exception {
  TileCodecException(this.code, this.message);

  /// Stable, machine-readable reason, mirrored into the JSON error envelope.
  final String code;
  final String message;

  @override
  String toString() => 'TileCodecException($code): $message';
}

/// An in-memory sky-atlas tile accumulator: the six running vectors plus the
/// structured header. This is the Dart analogue of Rust `SkyTileAccumulator`,
/// holding exactly the state needed to merge, finalize, and re-serialize.
class TileAccumulator {
  TileAccumulator({
    required this.version,
    required this.header,
    required this.sumW,
    required this.sumW2,
    required this.sumWx,
    required this.sumWx2,
    required this.coverage,
    required this.rejected,
  });

  /// Format version read from the blob (always [tileStateVersion] for now).
  final int version;

  /// The raw JSON header, round-tripped verbatim so unknown keystone keys
  /// survive a merge. Interpreted via the typed getters below.
  final Map<String, Object?> header;

  final Float64List sumW;
  final Float64List sumW2;
  final Float64List sumWx;
  final Float64List sumWx2;
  final Uint32List coverage;
  final Uint32List rejected;

  int get tileId => _headerInt('tile_id');
  int get order => _headerInt('order');
  int get width => _headerInt('width');
  int get height => _headerInt('height');
  int get channels => _headerInt('channels');

  /// Number of pixel/channel slots (= width × height × channels).
  int get slotCount => sumW.length;

  /// Total frames folded across every contributor, from provenance.
  int get totalFrames => _provenanceInt('total_frames');

  /// Total integration seconds across every contributor, from provenance.
  double get totalIntegrationSeconds =>
      _provenanceDouble('total_integration_seconds');

  /// Distinct contributor ids that have folded into this tile.
  List<String> get contributors {
    final prov = _provenance;
    final raw = prov['contributors'];
    if (raw is! List) return const <String>[];
    return raw.map((Object? e) => e.toString()).toList(growable: false);
  }

  Map<String, Object?> get _provenance {
    final prov = header['provenance'];
    if (prov is Map<String, Object?>) return prov;
    if (prov is Map) {
      return prov.map(
        (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
      );
    }
    return <String, Object?>{};
  }

  int _headerInt(String key) {
    final v = header[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    throw TileCodecException(
      'corrupt',
      'tile header missing integer field "$key"',
    );
  }

  int _provenanceInt(String key) {
    final v = _provenance[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  double _provenanceDouble(String key) {
    final v = _provenance[key];
    if (v is num) return v.toDouble();
    return 0;
  }

  /// Parse a `.skt` blob into a [TileAccumulator]. Fails loudly (matching the
  /// Rust `deserialize`) on bad magic, an unsupported version, a truncated
  /// payload, or geometry that disagrees with the declared slot count.
  static TileAccumulator deserialize(Uint8List bytes) {
    if (bytes.length < _fixedPrefixBytes) {
      throw TileCodecException(
        'corrupt',
        'truncated: ${bytes.length} bytes, need at least $_fixedPrefixBytes',
      );
    }
    var magicOk = true;
    var legacyMagicOk = true;
    for (var i = 0; i < 4; i++) {
      magicOk &= bytes[i] == tileMagic[i];
      legacyMagicOk &= bytes[i] == legacyTileMagic[i];
    }
    if (!magicOk && !legacyMagicOk) {
      throw TileCodecException(
        'badMagic',
        'not a Skotiq tile sidecar (bad magic)',
      );
    }
    final view = ByteData.sublistView(bytes);
    final version = view.getUint32(4, Endian.little);
    if (version != tileStateVersion) {
      throw TileCodecException(
        'unsupportedVersion',
        'unsupported tile version $version (this build reads $tileStateVersion)',
      );
    }
    final headerLen = view.getUint32(8, Endian.little);
    final headerEnd = _fixedPrefixBytes + headerLen;
    if (bytes.length < headerEnd) {
      throw TileCodecException('corrupt', 'truncated header');
    }
    final headerJson = utf8.decode(bytes.sublist(_fixedPrefixBytes, headerEnd));
    final decoded = jsonDecode(headerJson);
    if (decoded is! Map) {
      throw TileCodecException('corrupt', 'tile header is not a JSON object');
    }
    final header = decoded.map(
      (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
    );

    final declaredSlots = _intField(header, 'slot_count');
    final width = _intField(header, 'width');
    final height = _intField(header, 'height');
    final channels = _intField(header, 'channels');
    final geomSlots = width * height * channels;
    if (declaredSlots != geomSlots) {
      throw TileCodecException(
        'corrupt',
        'slot count ($declaredSlots) disagrees with declared geometry '
            '($geomSlots)',
      );
    }

    final len = declaredSlots;
    final f64Bytes = len * 8;
    final u32Bytes = len * 4;
    final payloadLen = f64Bytes * 4 + u32Bytes * 2;
    final total = headerEnd + payloadLen;
    if (bytes.length < total) {
      throw TileCodecException(
        'corrupt',
        'truncated payload: ${bytes.length} bytes, need $total',
      );
    }

    var cursor = headerEnd;
    // Every float vector is read AND validated: an untrusted contributor controls
    // every byte of the .skt, so a single NaN/Inf in any weighted-sum slot would,
    // once merged via mergeSigned, permanently poison the shared base (NaN - NaN
    // stays NaN, so retract() cannot remove it). Reject the whole blob on the
    // first non-finite value rather than ever letting it reach the merge.
    final sumW = _readF64(view, cursor, len, 'sum_w');
    cursor += f64Bytes;
    final sumW2 = _readF64(view, cursor, len, 'sum_w2');
    cursor += f64Bytes;
    final sumWx = _readF64(view, cursor, len, 'sum_wx');
    cursor += f64Bytes;
    final sumWx2 = _readF64(view, cursor, len, 'sum_wx2');
    cursor += f64Bytes;
    final coverage = _readU32(view, cursor, len);
    cursor += u32Bytes;
    final rejected = _readU32(view, cursor, len);

    return TileAccumulator(
      version: version,
      header: header,
      sumW: sumW,
      sumW2: sumW2,
      sumWx: sumWx,
      sumWx2: sumWx2,
      coverage: coverage,
      rejected: rejected,
    );
  }

  /// Serialize back to the exact `.skt` layout the keystone emits.
  Uint8List serialize() {
    // Keep header.slot_count consistent with the live payload length.
    final headerOut = Map<String, Object?>.from(header)
      ..['slot_count'] = slotCount;
    final headerJson = utf8.encode(jsonEncode(headerOut));
    final len = slotCount;
    final payloadLen = len * 8 * 4 + len * 4 * 2;
    final out = Uint8List(_fixedPrefixBytes + headerJson.length + payloadLen);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < 4; i++) {
      out[i] = tileMagic[i];
    }
    view.setUint32(4, tileStateVersion, Endian.little);
    view.setUint32(8, headerJson.length, Endian.little);
    out.setRange(
      _fixedPrefixBytes,
      _fixedPrefixBytes + headerJson.length,
      headerJson,
    );

    var cursor = _fixedPrefixBytes + headerJson.length;
    cursor = _writeF64(view, cursor, sumW);
    cursor = _writeF64(view, cursor, sumW2);
    cursor = _writeF64(view, cursor, sumWx);
    cursor = _writeF64(view, cursor, sumWx2);
    cursor = _writeU32(view, cursor, coverage);
    cursor = _writeU32(view, cursor, rejected);
    return out;
  }

  /// Finalized per-pixel mean (`sum_wx / sum_w`, 0 where uncovered). The hub
  /// uses this to gate quality and (optionally) emit a preview; it mirrors
  /// `SkyTileAccumulator::finalize`.
  Float64List finalizeMean() {
    final out = Float64List(slotCount);
    for (var i = 0; i < slotCount; i++) {
      final w = sumW[i];
      out[i] = w > 0 ? sumWx[i] / w : 0.0;
    }
    return out;
  }

  /// A deep, independent copy (so a merge never aliases the base operand).
  TileAccumulator clone() {
    return TileAccumulator(
      version: version,
      header: _deepCopyHeader(header),
      sumW: Float64List.fromList(sumW),
      sumW2: Float64List.fromList(sumW2),
      sumWx: Float64List.fromList(sumWx),
      sumWx2: Float64List.fromList(sumWx2),
      coverage: Uint32List.fromList(coverage),
      rejected: Uint32List.fromList(rejected),
    );
  }

  static int _intField(Map<String, Object?> header, String key) {
    final v = header[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    throw TileCodecException(
      'corrupt',
      'tile header missing integer field "$key"',
    );
  }

  static Float64List _readF64(
    ByteData view,
    int offset,
    int len,
    String field,
  ) {
    final out = Float64List(len);
    for (var i = 0; i < len; i++) {
      final v = view.getFloat64(offset + i * 8, Endian.little);
      if (!v.isFinite) {
        throw TileCodecException(
          'corrupt',
          'non-finite value in "$field" at slot $i (NaN/Inf rejected)',
        );
      }
      out[i] = v;
    }
    return out;
  }

  static Uint32List _readU32(ByteData view, int offset, int len) {
    final out = Uint32List(len);
    for (var i = 0; i < len; i++) {
      out[i] = view.getUint32(offset + i * 4, Endian.little);
    }
    return out;
  }

  static int _writeF64(ByteData view, int offset, Float64List src) {
    for (var i = 0; i < src.length; i++) {
      view.setFloat64(offset + i * 8, src[i], Endian.little);
    }
    return offset + src.length * 8;
  }

  static int _writeU32(ByteData view, int offset, Uint32List src) {
    for (var i = 0; i < src.length; i++) {
      view.setUint32(offset + i * 4, src[i], Endian.little);
    }
    return offset + src.length * 4;
  }
}

Map<String, Object?> _deepCopyHeader(Map<String, Object?> header) {
  final encoded = jsonEncode(header);
  final decoded = jsonDecode(encoded);
  return (decoded as Map).map(
    (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
  );
}

/// Overwrite [delta]'s provenance with server-authoritative values before it is
/// merged: the contributor id is forced to the authenticated [accountId], and
/// the frame/integration totals come from the server-validated [framesDelta] /
/// [integrationSecondsDelta] rather than the uploader's self-reported header.
///
/// This is the federation trust boundary. Without it a contributor could inflate
/// `total_frames` / `total_integration_seconds` (surfaced unauthenticated via the
/// `x-total-frames` / `x-integration-seconds` headers) or forge other accounts'
/// ids into `contributors`, falsely attributing data and corrupting the count.
void sanitizeContributionProvenance(
  TileAccumulator delta, {
  required String accountId,
  required int framesDelta,
  required double integrationSecondsDelta,
}) {
  final prov = _mutableProvenance(delta.header);
  prov['total_frames'] = framesDelta;
  prov['total_integration_seconds'] = integrationSecondsDelta;
  // The contributor union in _mergeProvenance is driven by each fold's
  // `contributor`, so every fold the merge will read must carry the authenticated
  // id — that is the only contributor this upload may attribute data to.
  final folds = _mutableFolds(prov);
  for (final fold in folds) {
    fold['contributor'] = accountId;
  }
  prov['folds'] = folds;
  prov['contributors'] = <String>[accountId];
  delta.header['provenance'] = prov;
}

/// Element-wise `dst += sign * trust * other` over the four weighted sums, with
/// coverage/rejection tallies added (or subtracted, clamped at zero) unscaled,
/// and a provenance union (or retraction). `sign` is `+1` to fuse, `-1` to
/// retract.
///
/// This is the exact algebra of `sky_atlas.rs::merge_signed`. It mutates and
/// returns [dst]. Operands must share id, order, channels, and slot count or a
/// [TileCodecException] is thrown with a 409-mapping code.
TileAccumulator mergeSigned(
  TileAccumulator dst,
  TileAccumulator other,
  double trust,
  double sign,
) {
  if (dst.order != other.order) {
    throw TileCodecException(
      'orderMismatch',
      'tile order mismatch: ${other.order} vs ${dst.order}',
    );
  }
  if (dst.tileId != other.tileId) {
    throw TileCodecException(
      'geometryMismatch',
      'tile geometry mismatch: ${other.tileId} vs ${dst.tileId}',
    );
  }
  if (dst.channels != other.channels) {
    throw TileCodecException(
      'channelMismatch',
      'channel mismatch: ${other.channels} vs ${dst.channels}',
    );
  }
  if (dst.slotCount != other.slotCount) {
    throw TileCodecException(
      'corrupt',
      'merge operands have mismatched slot counts '
          '(${other.slotCount} vs ${dst.slotCount})',
    );
  }

  final k = sign * trust;
  // sum_w2 = Σw² is QUADRATIC in the weight, so scaling a contributor's
  // effective weight by `trust` scales its Σw² by trust², not trust (the sign
  // stays linear). This MUST match `sky_atlas.rs::merge_signed`, which uses
  // `k2 = sign * trust * trust` for sum_w2 — using `k` here would leave a
  // trust!=1.0 merged tile with Σw scaled by trust but Σw² by trust, an
  // inconsistent state that breaks the online clip's effective-sample-size
  // denominator `sw - sum_w2/sw` and silently diverges from the keystone.
  final k2 = sign * trust * trust;
  final len = dst.slotCount;
  for (var i = 0; i < len; i++) {
    dst.sumW[i] += k * other.sumW[i];
    dst.sumW2[i] += k2 * other.sumW2[i];
    dst.sumWx[i] += k * other.sumWx[i];
    dst.sumWx2[i] += k * other.sumWx2[i];
    if (sign >= 0) {
      dst.coverage[i] = _satAddU32(dst.coverage[i], other.coverage[i]);
      dst.rejected[i] = _satAddU32(dst.rejected[i], other.rejected[i]);
    } else {
      dst.coverage[i] = _satSubU32(dst.coverage[i], other.coverage[i]);
      dst.rejected[i] = _satSubU32(dst.rejected[i], other.rejected[i]);
    }
  }

  _mergeProvenance(dst, other, sign);
  return dst;
}

void _mergeProvenance(TileAccumulator dst, TileAccumulator other, double sign) {
  final dstProv = _mutableProvenance(dst.header);
  final otherProv = _mutableProvenance(other.header);

  final dstFrames = (dstProv['total_frames'] as num?)?.toInt() ?? 0;
  final otherFrames = (otherProv['total_frames'] as num?)?.toInt() ?? 0;
  final dstSeconds =
      (dstProv['total_integration_seconds'] as num?)?.toDouble() ?? 0.0;
  final otherSeconds =
      (otherProv['total_integration_seconds'] as num?)?.toDouble() ?? 0.0;

  final dstFolds = _mutableFolds(dstProv);
  final otherFolds = _readFolds(otherProv);
  final contributors = _mutableContributors(dstProv);

  if (sign >= 0) {
    dstProv['total_frames'] = dstFrames + otherFrames;
    dstProv['total_integration_seconds'] = dstSeconds + otherSeconds;
    for (final fold in otherFolds) {
      final who = (fold['contributor'] ?? '').toString();
      if (!contributors.contains(who)) contributors.add(who);
      dstFolds.add(fold);
    }
  } else {
    dstProv['total_frames'] = (dstFrames - otherFrames).clamp(0, dstFrames);
    dstProv['total_integration_seconds'] = (dstSeconds - otherSeconds).clamp(
      0.0,
      dstSeconds,
    );
    for (final fold in otherFolds) {
      dstFolds.add(<String, Object?>{
        'frames_added': (fold['frames_added'] as num?)?.toInt() ?? 0,
        'weight_added': -((fold['weight_added'] as num?)?.toDouble() ?? 0.0),
        'integration_seconds_added':
            -((fold['integration_seconds_added'] as num?)?.toDouble() ?? 0.0),
        'rejected': (fold['rejected'] as num?)?.toInt() ?? 0,
        'label': 'retract:${fold['label'] ?? ''}',
        'contributor': (fold['contributor'] ?? '').toString(),
      });
    }
  }

  dstProv['contributors'] = contributors;
  dstProv['folds'] = dstFolds;
  dst.header['provenance'] = dstProv;
}

Map<String, Object?> _mutableProvenance(Map<String, Object?> header) {
  final prov = header['provenance'];
  if (prov is Map<String, Object?>) return prov;
  if (prov is Map) {
    final coerced = prov.map(
      (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
    );
    header['provenance'] = coerced;
    return coerced;
  }
  final fresh = <String, Object?>{
    'total_frames': 0,
    'total_integration_seconds': 0.0,
    'contributors': <String>[],
    'folds': <Object?>[],
  };
  header['provenance'] = fresh;
  return fresh;
}

List<String> _mutableContributors(Map<String, Object?> prov) {
  final raw = prov['contributors'];
  if (raw is List) {
    return raw.map((Object? e) => e.toString()).toList();
  }
  return <String>[];
}

List<Map<String, Object?>> _mutableFolds(Map<String, Object?> prov) {
  return _readFolds(prov).toList();
}

List<Map<String, Object?>> _readFolds(Map<String, Object?> prov) {
  final raw = prov['folds'];
  if (raw is! List) return <Map<String, Object?>>[];
  return raw.whereType<Map>().map((Map e) {
    return e.map(
      (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
    );
  }).toList();
}

int _satAddU32(int a, int b) {
  final sum = a + b;
  return sum > 0xFFFFFFFF ? 0xFFFFFFFF : sum;
}

int _satSubU32(int a, int b) {
  final diff = a - b;
  return diff < 0 ? 0 : diff;
}
