import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as path;

/// Persists a per-channel monotonic watermark of the newest update
/// `releaseDate` this host has accepted, so a later check cannot be frozen
/// or rolled back to an older signed release (anti-freeze / anti-rollback).
///
/// The watermark is meaningful because `releaseDate` is part of the signed
/// canonical payload — an attacker cannot backdate a manifest without
/// breaking the Ed25519 signature. Keyed per channel so `stable` and `beta`
/// never cross-contaminate each other's high-water mark.
///
/// Stored at `<appSupport>/updates/anti_freeze.json` as
/// `{ "<channel>": { "maxReleaseDate": "<ISO8601 UTC>" } }`.
class AntiFreezeStore {
  final Future<Directory> Function() _applicationSupportDirectoryProvider;

  AntiFreezeStore(this._applicationSupportDirectoryProvider);

  Future<File> _file() async {
    final appData = await _applicationSupportDirectoryProvider();
    final updates = Directory(path.join(appData.path, 'updates'));
    if (!await updates.exists()) {
      await updates.create(recursive: true);
    }
    return File(path.join(updates.path, 'anti_freeze.json'));
  }

  Future<Map<String, dynamic>> _read() async {
    final file = await _file();
    if (!await file.exists()) {
      return {};
    }
    try {
      final raw = (await file.readAsString()).trim();
      if (raw.isEmpty) {
        return {};
      }
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, dynamic>() : {};
    } catch (e) {
      // A present-but-unreadable watermark file would otherwise be treated as
      // "no watermark", silently disabling the anti-rollback gate in
      // _assertManifestNotRolledBack. Surface it so the degradation is
      // observable. We still continue with no watermark rather than fail
      // closed: an attacker able to corrupt this file could instead delete it
      // (a missing file is legitimately empty), so failing closed adds no
      // protection while turning a benign disk glitch into a permanent
      // update outage. The bar is re-established on the next accepted update.
      developer.log(
        'Anti-freeze watermark file unreadable; proceeding without a '
        'rollback watermark on this read: $e',
        name: 'AntiFreezeStore',
        level: 900,
      );
      return {};
    }
  }

  /// The newest accepted `releaseDate` for [channel], or null when this host
  /// has never staged a verified update on that channel.
  Future<DateTime?> watermark(String channel) async {
    final entry = (await _read())[channel];
    if (entry is Map) {
      final raw = entry['maxReleaseDate'];
      if (raw is String) {
        return DateTime.tryParse(raw)?.toUtc();
      }
    }
    return null;
  }

  /// Move [channel]'s watermark forward to [releaseDate]. Never moves
  /// backward, so an out-of-order accept cannot lower the bar. Best-effort:
  /// a failure to persist must not block an already-verified update.
  Future<void> advance(String channel, DateTime releaseDate) async {
    final candidate = releaseDate.toUtc();
    final current = await watermark(channel);
    if (current != null && !candidate.isAfter(current)) {
      return;
    }
    final data = await _read();
    data[channel] = {'maxReleaseDate': candidate.toIso8601String()};
    try {
      await (await _file()).writeAsString(jsonEncode(data));
    } catch (_) {
      // Best-effort persistence; see doc comment.
    }
  }
}
