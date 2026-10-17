import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../database/daos/settings_dao.dart';
import '../smart_night_service.dart';

enum SmartNightDraftStatus { pending, started }

class SmartNightDraft {
  final String id;
  final String profileId;
  final DateTime astronomicalDay;
  final SmartNightDraftStatus status;
  final SmartNightPlan plan;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SmartNightDraft({
    required this.id,
    required this.profileId,
    required this.astronomicalDay,
    required this.status,
    required this.plan,
    required this.createdAt,
    required this.updatedAt,
  });

  SmartNightDraft copyWith({
    SmartNightDraftStatus? status,
    SmartNightPlan? plan,
    DateTime? updatedAt,
  }) {
    return SmartNightDraft(
      id: id,
      profileId: profileId,
      astronomicalDay: astronomicalDay,
      status: status ?? this.status,
      plan: plan ?? this.plan,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'profileId': profileId,
    'astronomicalDay': _dateKey(astronomicalDay),
    'status': status.name,
    'plan': plan.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory SmartNightDraft.fromJson(Map<String, dynamic> json) {
    return SmartNightDraft(
      id: json['id'] as String,
      profileId: json['profileId'] as String,
      astronomicalDay: _parseDateKey(json['astronomicalDay'] as String),
      status: SmartNightDraftStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => SmartNightDraftStatus.pending,
      ),
      plan: SmartNightPlan.fromJson((json['plan'] as Map).cast()),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

class SmartNightDraftService {
  static const settingsKey = 'smart_night.drafts.v1';
  static const pendingTtl = Duration(hours: 24);
  static const _uuid = Uuid();

  final SettingsDao settingsDao;
  final DateTime Function() _now;

  const SmartNightDraftService({
    required this.settingsDao,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  Future<SmartNightDraft> savePending({
    required String profileId,
    required DateTime astronomicalDay,
    required SmartNightPlan plan,
  }) async {
    final now = _now();
    final day = _dateOnly(astronomicalDay);
    final drafts = await loadAll();
    drafts.removeWhere(
      (d) =>
          d.profileId == profileId &&
          _dateKey(d.astronomicalDay) == _dateKey(day),
    );
    final draft = SmartNightDraft(
      id: _uuid.v4(),
      profileId: profileId,
      astronomicalDay: day,
      status: SmartNightDraftStatus.pending,
      plan: plan,
      createdAt: now,
      updatedAt: now,
    );
    drafts.add(draft);
    await _saveAll(drafts);
    return draft;
  }

  Future<SmartNightDraft?> loadPending({
    required String profileId,
    required DateTime astronomicalDay,
  }) async {
    await cleanupExpiredPending();
    final dayKey = _dateKey(astronomicalDay);
    final drafts = await loadAll();
    return drafts.cast<SmartNightDraft?>().lastWhere(
      (d) =>
          d != null &&
          d.profileId == profileId &&
          _dateKey(d.astronomicalDay) == dayKey &&
          d.status == SmartNightDraftStatus.pending,
      orElse: () => null,
    );
  }

  Future<SmartNightDraft?> loadById(String id) async {
    final drafts = await loadAll();
    return drafts.cast<SmartNightDraft?>().firstWhere(
      (d) => d?.id == id,
      orElse: () => null,
    );
  }

  Future<void> markStarted(String id) async {
    final now = _now();
    final drafts = await loadAll();
    final index = drafts.indexWhere((d) => d.id == id);
    if (index < 0) return;
    drafts[index] = drafts[index].copyWith(
      status: SmartNightDraftStatus.started,
      updatedAt: now,
    );
    await _saveAll(drafts);
  }

  Future<void> cleanupExpiredPending() async {
    final cutoff = _now().subtract(pendingTtl);
    final drafts = await loadAll();
    final before = drafts.length;
    drafts.removeWhere(
      (d) =>
          d.status == SmartNightDraftStatus.pending &&
          d.updatedAt.isBefore(cutoff),
    );
    if (drafts.length != before) {
      await _saveAll(drafts);
    }
  }

  Future<List<SmartNightDraft>> loadAll() async {
    final raw = await settingsDao.getSetting(settingsKey);
    if (raw == null || raw.trim().isEmpty) return <SmartNightDraft>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Smart Night draft store must be a list');
    }
    return decoded
        .map((e) => SmartNightDraft.fromJson((e as Map).cast()))
        .toList();
  }

  Future<void> _saveAll(List<SmartNightDraft> drafts) {
    final encoded = jsonEncode(drafts.map((d) => d.toJson()).toList());
    return settingsDao.setSetting(settingsKey, encoded);
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

String _dateKey(DateTime value) {
  final date = _dateOnly(value);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}

DateTime _parseDateKey(String value) {
  final parts = value.split('-');
  if (parts.length != 3) {
    throw FormatException('Invalid astronomical day: $value');
  }
  return DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}
