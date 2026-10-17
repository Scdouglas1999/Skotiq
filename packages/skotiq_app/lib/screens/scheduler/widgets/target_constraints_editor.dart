import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
// skotiq_core re-exports a `ConnectionState` from its device-types model
// that collides with Flutter's async `ConnectionState`. Hide the core one
// here; everything else we need from the barrel is unaffected.
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
// horizonProfilesSchemaSql is intentionally hidden from the package barrel
// (it's a DDL constant, not public API). Pull it in via the source file
// directly so the local (host) path can guarantee the table exists before
// reading. On a remote slave horizon profiles come from the host over REST.
// ignore: implementation_imports
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart'
    show horizonProfilesSchemaSql;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../accessible_dropdown.dart';

part 'target_constraints_editor/constraint_rows.dart';
part 'target_constraints_editor/constraint_fields.dart';
part 'target_constraints_editor/add_constraint_wizard_dialog.dart';
part 'target_constraints_editor/wizard_kind_step.dart';
part 'target_constraints_editor/wizard_params_review.dart';

///
/// Manages four constraint kinds:
///   * timeWindow:            HH:MM start / HH:MM end (local time).
///   * moonIlluminationMax:   0..1 slider.
///   * customHorizon:         picks an existing HorizonProfile by id.
///   * scheduledWindow:       absolute-UTC forced-priority window.
///
/// Constraints are persisted directly via raw SQL through the
/// shared database provider (no dedicated DAO exists yet — matching the
/// scheduler engine's loader which does the same). Editing emits a
/// candidatesUpdated trigger upstream so the engine re-evaluates.
///
/// "Add constraint" opens a 3-step wizard (kind → params with defaults →
/// review). "Edit constraint" keeps the existing direct-dialog form so
/// power users tweaking a single row don't pay a 3-step tax.
class TargetConstraintsEditor extends ConsumerStatefulWidget {
  final int targetId;
  final String targetName;
  final VoidCallback? onChanged;

  const TargetConstraintsEditor({
    super.key,
    required this.targetId,
    required this.targetName,
    this.onChanged,
  });

  @override
  ConsumerState<TargetConstraintsEditor> createState() =>
      _TargetConstraintsEditorState();
}

class _TargetConstraintsEditorState
    extends ConsumerState<TargetConstraintsEditor> {
  late Future<_LoadedConstraints> _future;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        setState(() {
          _future = _load();
        });
      },
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  Future<_LoadedConstraints> _load() async {
    // Constraints come through the (now host-aware) service, so on a remote
    // slave they reflect the HOST's rows rather than the slave's empty local
    // table. Horizon profiles are sourced from the host too on a slave.
    final backend = ref.read(backendProvider);
    final svc = ref.read(targetConstraintServiceProvider);
    final constraints = await svc.listForTarget(widget.targetId);

    final List<HorizonProfile> profiles;
    if (backend is NetworkBackend) {
      profiles = (await backend.getHorizonProfiles())
        ..sort((a, b) => a.name.compareTo(b.name));
    } else {
      final db = ref.read(databaseProvider);
      await db.customStatement(horizonProfilesSchemaSql);
      final hpRows = await db
          .customSelect(
            'SELECT id, name, samples_json FROM horizon_profiles ORDER BY name ASC',
          )
          .get();
      profiles = hpRows
          .map((r) => HorizonProfile.fromRow(
                id: r.read<int>('id'),
                name: r.read<String>('name'),
                samplesJson: r.read<String>('samples_json'),
              ))
          .toList();
    }

    return _LoadedConstraints(
      authority: backend,
      service: svc,
      constraints: constraints,
      horizonProfiles: profiles,
    );
  }

  bool _isCurrentAuthority(_LoadedConstraints loaded) =>
      mounted && identical(ref.read(backendProvider), loaded.authority);

  void _showAuthorityChanged() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'The imaging host changed. Reopen the constraint editor.',
        ),
      ),
    );
  }

  Future<void> _refresh(_LoadedConstraints loaded) async {
    if (!_isCurrentAuthority(loaded)) return;
    setState(() {
      _future = _load();
    });
    final result = await _future;
    if (!_isCurrentAuthority(loaded)) return;
    setState(() {});
    widget.onChanged?.call();
    return Future.value(result).then((_) {});
  }

  Future<void> _upsertConstraint(
    TargetConstraint c,
    _LoadedConstraints loaded,
  ) async {
    if (!_isCurrentAuthority(loaded)) {
      _showAuthorityChanged();
      return;
    }
    final svc = loaded.service;
    if (c.id == null) {
      await svc.insert(c);
    } else {
      await svc.update(c);
    }
    if (!_isCurrentAuthority(loaded)) return;
    await _refresh(loaded);
  }

  Future<void> _deleteConstraint(int id, _LoadedConstraints loaded) async {
    if (!_isCurrentAuthority(loaded)) {
      _showAuthorityChanged();
      return;
    }
    await loaded.service.delete(id);
    if (!_isCurrentAuthority(loaded)) return;
    await _refresh(loaded);
  }

  Future<void> _openWizard(_LoadedConstraints loaded) async {
    final created = await showDialog<TargetConstraint>(
      context: context,
      barrierDismissible: false,
      builder: (dCtx) => _AddConstraintWizardDialog(
        targetId: widget.targetId,
        targetName: widget.targetName,
        horizonProfiles: loaded.horizonProfiles,
        existingKinds: loaded.constraints.map((c) => c.kind).toSet(),
      ),
    );
    if (created == null) return;
    if (!_isCurrentAuthority(loaded)) {
      _showAuthorityChanged();
      return;
    }
    await _upsertConstraint(created, loaded);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return FutureBuilder<_LoadedConstraints>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.primary,
              ),
            ),
          );
        }
        if (snap.hasError) {
          return Text(
            'Failed to load constraints: ${snap.error}',
            style: SkotiqTypography.caption.copyWith(color: colors.error),
          );
        }
        final loaded = snap.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.filter,
                    size: SkotiqTokens.iconSm, color: colors.primary),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(
                  'Hard constraints',
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              'A failing constraint excludes ${widget.targetName} from selection regardless of score.',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            for (final c in loaded.constraints)
              _ConstraintRow(
                constraint: c,
                horizonProfiles: loaded.horizonProfiles,
                onChange: (constraint) => _upsertConstraint(constraint, loaded),
                onDelete: () => _deleteConstraint(c.id!, loaded),
              ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            _AddConstraintButton(
              key: const ValueKey('add-constraint-wizard-button'),
              onPressed: () => _openWizard(loaded),
            ),
          ],
        );
      },
    );
  }
}
