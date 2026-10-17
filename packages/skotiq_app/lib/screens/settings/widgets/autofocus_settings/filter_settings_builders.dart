// ignore_for_file: invalid_use_of_protected_member
// Filter settings section, table and mobile-card builders.
part of '../autofocus_settings.dart';

extension _AutofocusFilterSettingsBuilders on _AutofocusSettingsState {
  Widget _buildFilterSettingsSection(
    AppSettingsState settings,
    AppSettingsNotifier notifier,
    FilterWheelState filterWheelState,
  ) {
    final filterNames = filterWheelState.filterNames;
    final isConnected =
        filterWheelState.connectionState == DeviceConnectionState.connected;

    if (!isConnected || filterNames.isEmpty) {
      return SettingsSection(
        title: 'Autofocus filter settings',
        isMobile: widget.isMobile,
        children: [
          SettingRow(
            icon: LucideIcons.info,
            title: 'No filter wheel connected',
            subtitle:
                'Connect a filter wheel to configure per-filter autofocus settings.',
            trailing: const SizedBox.shrink(),
            isLast: true,
            isMobile: widget.isMobile,
          ),
        ],
      );
    }

    // Parse the current per-filter settings JSON
    final filterSettingsMap = AutofocusSettings.parseFilterSettingsJson(
      settings.afFilterSettingsJson,
    );

    return SettingsSection(
      title: 'Autofocus filter settings',
      isMobile: widget.isMobile,
      children: [
        if (widget.isMobile)
          ..._buildFilterSettingsMobile(
              filterNames, filterSettingsMap, notifier, settings)
        else
          _buildFilterSettingsTable(
              filterNames, filterSettingsMap, notifier, settings),
      ],
    );
  }

  Widget _buildFilterSettingsTable(
    List<String> filterNames,
    Map<String, FilterAutofocusConfig> filterSettingsMap,
    AppSettingsNotifier notifier,
    AppSettingsState settings,
  ) {
    return Column(
      children: [
        // Table header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: SkotiqColors.of(context).border),
            ),
          ),
          child: Row(
            children: [
              _tableHeader('Pos', width: 40),
              _tableHeader('Name', flex: 2),
              _tableHeader('Focus Offset', flex: 2),
              _tableHeader('AF Exp Time', flex: 2),
              _tableHeader('AF Filter', flex: 2),
              _tableHeader('Binning', width: 70),
              _tableHeader('Gain', flex: 1),
              _tableHeader('Offset', flex: 1),
            ],
          ),
        ),
        // Table rows
        ...List.generate(filterNames.length, (index) {
          final filterName = filterNames[index];
          final config =
              filterSettingsMap[filterName] ?? const FilterAutofocusConfig();
          final isLast = index == filterNames.length - 1;

          return _FilterSettingsRow(
            position: index + 1,
            filterName: filterName,
            config: config,
            allFilterNames: filterNames,
            isLast: isLast,
            onConfigChanged: (update) =>
                notifier.updateFilterAutofocusConfig(filterName, update),
          );
        }),
        // Autofocus filter selector
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: SkotiqColors.of(context).border),
            ),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.focus,
                  size: 16, color: SkotiqColors.of(context).textSecondary),
              const SizedBox(width: 10),
              Text(
                'Designated autofocus filter:',
                style: SkotiqTypography.labelSm
                    .copyWith(color: SkotiqColors.of(context).textPrimary),
              ),
              const SizedBox(width: 12),
              SettingsDropdown(
                value: settings.afAutofocusFilterName.isEmpty
                    ? 'Current filter'
                    : settings.afAutofocusFilterName,
                items: ['Current filter', ...filterNames],
                onChanged: (value) {
                  return notifier.setAfAutofocusFilterName(
                    value == 'Current filter' ? '' : value,
                  );
                },
                width: 180,
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildFilterSettingsMobile(
    List<String> filterNames,
    Map<String, FilterAutofocusConfig> filterSettingsMap,
    AppSettingsNotifier notifier,
    AppSettingsState settings,
  ) {
    final widgets = <Widget>[];

    for (int index = 0; index < filterNames.length; index++) {
      final filterName = filterNames[index];
      final config =
          filterSettingsMap[filterName] ?? const FilterAutofocusConfig();

      widgets.add(
        _FilterSettingsMobileCard(
          position: index + 1,
          filterName: filterName,
          config: config,
          allFilterNames: filterNames,
          isLast: index == filterNames.length - 1,
          onConfigChanged: (update) =>
              notifier.updateFilterAutofocusConfig(filterName, update),
        ),
      );
    }

    // Autofocus filter selector
    widgets.add(
      SettingRow(
        icon: LucideIcons.focus,
        title: 'Designated autofocus filter',
        subtitle: 'Filter to switch to for AF runs',
        trailing: SettingsDropdown(
          value: settings.afAutofocusFilterName.isEmpty
              ? 'Current filter'
              : settings.afAutofocusFilterName,
          items: ['Current filter', ...filterNames],
          onChanged: (value) {
            return notifier.setAfAutofocusFilterName(
              value == 'Current filter' ? '' : value,
            );
          },
          isMobile: true,
        ),
        isLast: true,
        isMobile: true,
      ),
    );

    return widgets;
  }

  Widget _tableHeader(String text, {double? width, int? flex}) {
    final child = Text(
      text,
      style: SkotiqTypography.labelStrongSm
          .copyWith(color: SkotiqColors.of(context).textSecondary),
    );

    if (width != null) {
      return SizedBox(width: width, child: child);
    }
    return Expanded(flex: flex ?? 1, child: child);
  }
}
