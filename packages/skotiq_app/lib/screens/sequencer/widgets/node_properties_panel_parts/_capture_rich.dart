// Part of ../node_properties_panel.dart -- migrated from the former
// instruction_node_properties library. Richer
// capture-side editors: Cool/Warm camera, Filter change, and Notification
// (template title/message + transport multi-select + live preview).
part of '../node_properties_panel.dart';

class _CoolCameraProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final CoolCameraNode node;

  const _CoolCameraProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Cooling settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Target temperature',
          child: NodeNumberInput(
            colors: colors,
            value: node.targetTemp,
            suffix: '\u00B0C',
            min: -50,
            max: 30,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(targetTemp: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Max duration',
          child: NodeNumberInput(
            colors: colors,
            value: node.durationMins ?? 10,
            suffix: 'min',
            min: 1,
            max: 60,
            // Surface that 10 is the implicit fallback (not an explicit choice)
            // when the field has never been set.
            helperText: node.durationMins == null ? 'Default: 10 min' : null,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(durationMins: value),
                  );
            },
          ),
        ),
      ],
    );
  }
}

class _FilterChangeProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final FilterChangeNode node;

  const _FilterChangeProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The profile's filters, falling back to the connected wheel's — see
    // [builderFilterSource].
    final filterNames = builderFilterSource(ref).names;

    // Build list of filter options with their indices
    // Each item is a record of (index, name)
    final filterOptions = <({int index, String name})>[
      for (int i = 0; i < filterNames.length; i++)
        (index: i, name: filterNames[i]),
    ];

    // Find current selection. If the stored filter is no longer in the profile
    // we surface it as an explicit "(not in profile)" option and select it,
    // rather than silently snapping to the first filter (which would quietly
    // rewrite the node's filter on open).
    final matched = filterOptions.firstWhereOrNull(
      (f) => f.name == node.filterName || f.index == node.filterPosition,
    );
    final bool missingFromProfile = filterOptions.isNotEmpty &&
        matched == null &&
        node.filterName.isNotEmpty;
    if (missingFromProfile) {
      filterOptions.add((
        index: _kMissingFilterSentinel,
        name: '${node.filterName} (not in profile)'
      ));
    }
    final currentFilter =
        filterOptions.isEmpty ? null : (matched ?? filterOptions.last);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Filter settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Filter',
          child: filterOptions.isEmpty
              ? NodeTextInput(
                  colors: colors,
                  value: node.filterName,
                  hint: BuilderFilterSource.emptyHint,
                  onChanged: (value) {
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(filterName: value),
                        );
                  },
                )
              : Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: colors.surfaceAlt,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    border: Border.all(color: colors.border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: AccessibleDropdown<({int index, String name})>(
                      value: currentFilter,
                      isExpanded: true,
                      icon: Icon(
                        LucideIcons.chevronDown,
                        size: 16,
                        color: colors.textMuted,
                      ),
                      dropdownColor: colors.surface,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize13,
                        color: colors.textPrimary,
                      ),
                      items: filterOptions.map((filter) {
                        return DropdownMenuItem(
                          value: filter,
                          child: Text(filter.name),
                        );
                      }).toList(),
                      onChanged: (newValue) {
                        if (newValue != null) {
                          // The synthetic "not in profile" row is display-only.
                          if (newValue.index == _kMissingFilterSentinel) return;
                          // Set BOTH name and position for reliable filter changes
                          ref.read(currentSequenceProvider.notifier).updateNode(
                                node.copyWith(
                                  filterName: newValue.name,
                                  filterPosition: newValue.index,
                                ),
                              );
                        }
                      },
                    ),
                  ),
                ),
        ),
        if (missingFromProfile) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          // ONE inline line, not a paragraph: it says what is wrong and what
          // to do, and the button beside it is the doing.
          Row(
            children: [
              Icon(LucideIcons.alertTriangle, size: 12, color: colors.warning),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Expanded(
                child: Text(
                  'Filter is not in this profile.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.warning,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceSm),
        // A real button, not a link dressed as a row of muted text. Disabled
        // when there is no profile to edit, with the reason on the control
        // rather than in a sentence beside it.
        Align(
          alignment: Alignment.centerLeft,
          child: Builder(
            builder: (context) {
              final profile = ref.watch(activeEquipmentProfileProvider);
              return SkotiqButton(
                label: 'Edit filters',
                icon: LucideIcons.settings,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                semanticsHint: profile == null
                    ? 'No equipment profile is active, so there are no '
                        'filters to edit.'
                    : null,
                onPressed: profile == null
                    ? null
                    : () => ProfileEditorDialog.show(context, profile: profile),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _WarmCameraProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final WarmCameraNode node;

  const _WarmCameraProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Warming settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Warming rate',
          child: NodeNumberInput(
            colors: colors,
            value: node.ratePerMin,
            suffix: '\u00B0C/min',
            min: 0.5,
            max: 10,
            decimals: 1,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(ratePerMin: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Target temp',
          child: NodeNumberInput(
            colors: colors,
            value: node.targetTemp,
            suffix: '\u00B0C',
            min: 0,
            max: 35,
            decimals: 1,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(targetTemp: value),
                  );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: SkotiqDecorations.tintedBadge(
            colors.warning,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.alertTriangle, size: 14, color: colors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Gradual warming prevents thermal shock while warming toward ${node.targetTemp.toStringAsFixed(1)}°C',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 12),
                    color: colors.warning,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NotificationProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final NotificationNode node;

  const _NotificationProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Pull live transport configs so we know which
    // transports are *enabled & configured*. Showing every transport in
    // the chip list would confuse the user with "Telegram" chips that
    // can never actually fire because no bot token was saved.
    final emailAsync = ref.watch(emailTransportConfigProvider);
    final pushoverAsync = ref.watch(pushoverTransportConfigProvider);
    final telegramAsync = ref.watch(telegramTransportConfigProvider);
    final discordAsync = ref.watch(discordTransportConfigProvider);
    final mqttAsync = ref.watch(mqttTransportConfigProvider);
    final webhookAsync = ref.watch(webhookTransportConfigProvider);

    bool isConfigured(NotificationTransportKind kind) {
      switch (kind) {
        case NotificationTransportKind.inApp:
        case NotificationTransportKind.systemPush:
          // Always available — no credentials required.
          return true;
        case NotificationTransportKind.email:
          return emailAsync.valueOrNull?.isConfigured ?? false;
        case NotificationTransportKind.webhookGeneric:
          return webhookAsync.valueOrNull?.isConfigured ?? false;
        case NotificationTransportKind.pushover:
          return pushoverAsync.valueOrNull?.isConfigured ?? false;
        case NotificationTransportKind.telegram:
          return telegramAsync.valueOrNull?.isConfigured ?? false;
        case NotificationTransportKind.discord:
          return discordAsync.valueOrNull?.isConfigured ?? false;
        case NotificationTransportKind.mqtt:
          return mqttAsync.valueOrNull?.isConfigured ?? false;
      }
    }

    final selected =
        node.explicitTransports?.toSet() ?? <NotificationTransportKind>{};
    final fontSize = Responsive.fontSize(context, 13);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Notification Settings',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Title (template)',
          child: NodeTextInput(
            colors: colors,
            value: node.title,
            hint: r'e.g. Frame ${frame} of ${target.name} done',
            // The hint advertises ${...} tokens; without a picker the operator
            // has to know the catalog by heart. Same list the Rust evaluator
            // resolves.
            variables: interpolationCatalog,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(title: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Message (template, multi-line)',
          child: NodeTextInput(
            colors: colors,
            value: node.message,
            hint: r'e.g. Captured ${frame} frames at ${time.local}',
            maxLines: 4,
            variables: interpolationCatalog,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(message: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Level',
          child: NodeDropdown<NotificationLevel>(
            colors: colors,
            value: node.level,
            items: NotificationLevel.values,
            labelBuilder: (l) {
              switch (l) {
                case NotificationLevel.info:
                  return 'Info';
                case NotificationLevel.warning:
                  return 'Warning';
                case NotificationLevel.error:
                  return 'Error';
                case NotificationLevel.success:
                  return 'Success';
              }
            },
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(level: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Send via',
          child: _TransportMultiSelect(
            colors: colors,
            selected: selected,
            isConfigured: isConfigured,
            onChanged: (next) {
              if (next.isEmpty) {
                // NotificationNode.copyWith has no
                // `clearExplicitTransports`, so clearing back to the
                // matrix default requires constructing a new node
                // without the `explicitTransports` argument.
                ref.read(currentSequenceProvider.notifier).updateNode(
                      NotificationNode(
                        id: node.id,
                        name: node.name,
                        isEnabled: node.isEnabled,
                        childIds: node.childIds,
                        parentId: node.parentId,
                        orderIndex: node.orderIndex,
                        comment: node.comment,
                        title: node.title,
                        message: node.message,
                        level: node.level,
                      ),
                    );
              } else {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(explicitTransports: next.toList()),
                    );
              }
            },
          ),
        ),
        _NotificationPreview(colors: colors, node: node),
      ],
    );
  }
}

/// Chip-based multi-select for NotificationTransportKind. Greyed-out
/// chips for unconfigured transports so the user knows why their pick
/// won't fire until they fill in the credentials. Selecting an
/// unconfigured transport is still allowed — it just won't send until
/// the user goes to Settings → Notifications and configures it.
class _TransportMultiSelect extends StatelessWidget {
  final SkotiqColors colors;
  final Set<NotificationTransportKind> selected;
  final bool Function(NotificationTransportKind) isConfigured;
  final ValueChanged<Set<NotificationTransportKind>> onChanged;

  const _TransportMultiSelect({
    required this.colors,
    required this.selected,
    required this.isConfigured,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    const all = NotificationTransportKind.values;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Empty = use the matrix\'s default for "Custom" notifications. Tick one or more to override per-node.',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: all.map((kind) {
            final isSelected = selected.contains(kind);
            final configured = isConfigured(kind);
            return FilterChip(
              key: ValueKey('notif_transport_${kind.storageKey}'),
              label: Text(
                configured ? kind.label : '${kind.label} (not configured)',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: configured
                      ? (isSelected ? colors.background : colors.textPrimary)
                      : colors.textMuted,
                ),
              ),
              selected: isSelected,
              showCheckmark: false,
              selectedColor: colors.primary,
              backgroundColor: colors.surfaceAlt,
              side: BorderSide(
                color: configured
                    ? colors.border
                    : colors.warning.withValues(alpha: 0.6),
              ),
              onSelected: (sel) {
                final next = Set<NotificationTransportKind>.of(selected);
                if (sel) {
                  next.add(kind);
                } else {
                  next.remove(kind);
                }
                onChanged(next);
              },
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _NotificationPreview extends StatelessWidget {
  final SkotiqColors colors;
  final NotificationNode node;

  const _NotificationPreview({required this.colors, required this.node});

  @override
  Widget build(BuildContext context) {
    final title = previewInterpolation(node.title);
    final body = previewInterpolation(node.message);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              fontWeight: FontWeight.w700,
              color: colors.textMuted,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title.isEmpty ? '(no title)' : title,
            style: SkotiqTypography.labelStrong.copyWith(
                color: title.isEmpty ? colors.textMuted : colors.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            body.isEmpty ? '(no body)' : body,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              color: body.isEmpty ? colors.textMuted : colors.textSecondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
