part of '../projects_tab_content.dart';

/// Result returned by [_ProjectFormDialog] on save.
class _ProjectFormResult {
  final String name;
  final String? description;
  const _ProjectFormResult({required this.name, this.description});
}

// Header bar: project selector + create / edit / delete.

class _ProjectHeaderBar extends StatelessWidget {
  final SkotiqColors colors;
  final List<Project> projects;
  final Project active;
  final Future<void> Function(int) onSelect;
  final bool interactionBusy;
  final bool mutatingProject;
  final bool planningSmartNight;
  final Future<void> Function() onCreate;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onPlanInSmartNight;

  const _ProjectHeaderBar({
    required this.colors,
    required this.projects,
    required this.active,
    required this.onSelect,
    required this.interactionBusy,
    required this.mutatingProject,
    required this.planningSmartNight,
    required this.onCreate,
    required this.onEdit,
    required this.onDelete,
    required this.onPlanInSmartNight,
  });

  @override
  Widget build(BuildContext context) {
    // Project names are not guaranteed unique, so the dropdown value space is
    // the set of decimal ids (stable, unique), with names supplied as labels.
    final ids = projects
        .map((p) => p.id)
        .whereType<int>()
        .map((id) => id.toString())
        .toList();
    final labels = projects.map((p) => p.name).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceMd,
      ),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: SkotiqDropdown(
                value: active.id?.toString(),
                items: ids,
                itemLabels: labels,
                isExpanded: true,
                onChanged: interactionBusy || planningSmartNight
                    ? null
                    : (raw) {
                        if (raw == null) return;
                        final id = int.tryParse(raw);
                        if (id != null) {
                          onSelect(id);
                        }
                      },
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          AccessibleIconButton(
            icon: LucideIcons.pencil,
            label: 'Edit project',
            tooltip: 'Edit project',
            size: SkotiqTokens.iconMd,
            onPressed: interactionBusy || planningSmartNight ? null : onEdit,
          ),
          AccessibleIconButton(
            icon: LucideIcons.trash2,
            label: 'Delete project',
            tooltip: 'Delete project',
            color: colors.error,
            size: SkotiqTokens.iconMd,
            onPressed: interactionBusy || planningSmartNight ? null : onDelete,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: 'Plan tonight',
            icon: LucideIcons.sparkles,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            isLoading: planningSmartNight,
            onPressed: interactionBusy ? null : onPlanInSmartNight,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: 'New project',
            icon: LucideIcons.folderPlus,
            variant: ButtonVariant.primary,
            size: ButtonSize.small,
            isLoading: mutatingProject,
            onPressed:
                interactionBusy || planningSmartNight ? null : () => onCreate(),
          ),
        ],
      ),
    );
  }
}
