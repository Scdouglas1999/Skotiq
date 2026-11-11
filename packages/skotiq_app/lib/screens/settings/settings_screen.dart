import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';
import '../../widgets/tutorial_keys/settings_keys.dart';
import 'settings_catalog.dart';
import 'settings_search_index.g.dart';
import 'widgets/host_settings_notice.dart';
import 'widgets/settings_scope_notice.dart';
import 'widgets/settings_widgets.dart';

export 'settings_sections.dart';

part 'settings_screen_parts/_search_index.dart';
part 'settings_screen_parts/_desktop_layout.dart';
part 'settings_screen_parts/_mobile_layout.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  /// The section to open on. Null opens the first section.
  final SettingsSectionId? initialSection;

  const SettingsScreen({super.key, this.initialSection});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late SettingsSectionId _selected;

  GoRouteInformationProvider? _routes;

  /// On mobile, false means show the grouped list; true shows the detail pane.
  bool _mobileShowingDetail = false;

  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// Row title the detail pane should reveal, set when a search result names a
  /// specific row. Cleared a few seconds later by [_highlightTimer].
  String? _highlightRow;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSection;
    _selected = initial ?? SettingsSectionId.first;
    // A link that names a section wants the section, so on a phone it opens
    // the detail pane rather than the list.
    _mobileShowingDetail = initial != null;
    ShellBackDispatcher.register(_handleSystemBack);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routes = GoRouter.maybeOf(context)?.routeInformationProvider;
    if (identical(routes, _routes)) return;
    _routes?.removeListener(_onNavigation);
    _routes = routes?..addListener(_onNavigation);
  }

  /// Follows links into Settings while this screen is already open.
  ///
  /// `/settings` is one keyless page. A link to a section the route already
  /// names reaches this widget as a rebuild with unchanged arguments, so
  /// reading the section from the widget alone left most links dead once the
  /// operator had picked another section by hand. The router announces every
  /// navigation, including a repeat of the current location, so this listens
  /// to that instead: any link, from anywhere, lands.
  void _onNavigation() {
    final uri = _routes?.value.uri;
    if (!mounted || uri == null || uri.path != settingsPath) return;
    _showSection(SettingsSectionId.resolve(uri.queryParameters['section']));
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSection != oldWidget.initialSection) {
      _showSection(widget.initialSection);
    }
  }

  void _showSection(SettingsSectionId? section) {
    if (section == null) return;
    if (section == _selected && _mobileShowingDetail) return;
    _highlightTimer?.cancel();
    setState(() {
      _selected = section;
      _highlightRow = null;
      // The link named a destination, so on a phone the detail pane is the
      // destination, not the list.
      _mobileShowingDetail = true;
    });
  }

  @override
  void dispose() {
    _routes?.removeListener(_onNavigation);
    ShellBackDispatcher.unregister(_handleSystemBack);
    _highlightTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// System back on phone walks the in-screen stack before leaving the
  /// screen: detail pane → grouped list → clear an active search → let the
  /// shell take over (Dashboard / app exit).
  bool _handleSystemBack() {
    if (_mobileShowingDetail) {
      setState(() => _mobileShowingDetail = false);
      return true;
    }
    if (_query.isNotEmpty) {
      setState(() {
        _searchController.clear();
        _query = '';
      });
      return true;
    }
    return false;
  }

  SettingsSectionDef _selectedSection(List<SettingsGroupDef> groups) {
    for (final group in groups) {
      for (final section in group.sections) {
        if (section.id == _selected) return section;
      }
    }
    return groups.first.sections.first;
  }

  void _selectSection(
    SettingsSectionId section, {
    required bool isMobile,
    String? rowTitle,
  }) {
    _highlightTimer?.cancel();
    setState(() {
      _selected = section;
      _highlightRow = rowTitle;
      if (isMobile) _mobileShowingDetail = true;
    });
    if (rowTitle == null) return;
    // The tint is a pointer, not a state: leaving it on would make the row look
    // selected for the rest of the session.
    _highlightTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _highlightRow = null);
    });
  }

  /// Sections matching the live search query, best match first.
  ///
  /// The query is tokenised and every token must match, because
  /// [SettingsSectionDef.matches] is a substring test over single indexed
  /// phrases: the whole string "capture folder" is not a substring of any one
  /// row title, so the two-word phrase a user actually types returned "No
  /// settings match your search" while "folder" alone returned three sections.
  List<SettingsSearchResult> _searchResults(List<SettingsGroupDef> groups) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return const [];
    final tokens =
        query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return const [];

    final sections = <SettingsSectionDef>[];
    for (final group in groups) {
      for (final section in group.sections) {
        if (tokens.every(section.matches)) {
          sections.add(section);
        }
      }
    }
    // Stable sort: equal ranks keep sidebar order, so the list only ever
    // PROMOTES a better match rather than reshuffling the taxonomy.
    mergeSort<SettingsSectionDef>(
      sections,
      compare: (a, b) =>
          settingsMatchRank(a, query).compareTo(settingsMatchRank(b, query)),
    );
    return [
      for (final section in sections)
        SettingsSearchResult(section, matchingSettingsRows(section, tokens)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AppSettingsWriteFailure?>(appSettingsWriteFailureProvider, (
      previous,
      next,
    ) {
      if (next == null || identical(previous, next)) return;
      // An input that reports the failure beside itself takes it off the
      // channel as its write fails (`settingsReportRollback`), within this
      // turn of the event loop; what is still there afterwards nothing on
      // screen has reported.
      Timer.run(() {
        if (!mounted ||
            !identical(ref.read(appSettingsWriteFailureProvider), next)) {
          return;
        }
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(next.message),
              action: SnackBarAction(
                label: 'Retry',
                onPressed: () => ref.invalidate(appSettingsProvider),
              ),
            ),
          );
      });
    });
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final groups = buildSettingsGroups(context);

    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Phone tier (< 600 window): list -> full-screen detail navigation.
          //
          // The split view is also dropped whenever THIS screen — not the
          // window — is too narrow to host it. The window can be 800 px wide
          // while the settings body only gets ~580 px because the shell's
          // navigation rail already ate 220 px; a 260 px sidebar then leaves
          // ~320 px of detail, which is not enough for a settings row and
          // made the accent-colour swatches, path pickers, autofocus filter
          // table and calibration status cards overflow off-screen.
          final singlePane = Responsive.isPhone(context) ||
              (constraints.hasBoundedWidth &&
                  constraints.maxWidth < _splitPaneMinWidth);
          return singlePane
              ? _buildMobileLayout(colors, groups)
              : _buildDesktopLayout(colors, groups);
        },
      ),
    );
  }

  /// Minimum width this screen needs before the sidebar + detail split is
  /// worth showing. Below it the detail pane cannot hold a settings row at
  /// its design width, so the single-pane (list -> detail) flow is used.
  static const double _splitPaneMinWidth = 720;

  // Mobile

  Widget _buildMobileLayout(
    SkotiqColors colors,
    List<SettingsGroupDef> groups,
  ) {
    if (!_mobileShowingDetail) {
      return _MobileSectionList(
        groups: groups,
        searchController: _searchController,
        query: _query,
        results: _searchResults(groups),
        onQueryChanged: (value) => setState(() => _query = value),
        onSectionTap: (key, rowTitle) =>
            _selectSection(key, isMobile: true, rowTitle: rowTitle),
        colors: colors,
        title: context.l10n.text('settingsTitle'),
      );
    }

    final section = _selectedSection(groups);
    return Column(
      children: [
        // The detail pane is one step deeper than the list, so its header
        // leads with the way back rather than the screen's own name.
        Container(
          height: ShellChromeMetrics.pageHeaderHeightNarrow,
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceMd,
          ),
          decoration: BoxDecoration(
            color: colors.background,
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                SkotiqIconButton(
                  icon: LucideIcons.arrowLeft,
                  tooltip: 'Back to all settings',
                  onPressed: () => setState(() => _mobileShowingDetail = false),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    section.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.pageTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // SafeArea (sides + bottom) so a rotated phone's notch/home indicator
        // never clips the detail content; top is already handled by the header.
        Expanded(
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const HostSettingsNotice(),
                SettingsScopeNotice(section: section.id),
                Expanded(
                  child: SettingsFormScope(
                    isMobile: true,
                    authority: ref.watch(backendProvider),
                    child: SettingsRowHighlight(
                      rowTitle: _highlightRow,
                      child: Builder(builder: section.build),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Desktop

  Widget _buildDesktopLayout(
    SkotiqColors colors,
    List<SettingsGroupDef> groups,
  ) {
    final results = _searchResults(groups);
    final searching = _query.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          icon: LucideIcons.settings,
          title: context.l10n.text('settingsTitle'),
          actions: [
            SkotiqButton(
              label: context.l10n.text('settingsBackup'),
              icon: LucideIcons.download,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () =>
                  _selectSection(SettingsSectionId.backup, isMobile: false),
            ),
          ],
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DesktopNav(
                groups: groups,
                selected: _selected,
                colors: colors,
                searchController: _searchController,
                searching: searching,
                results: results,
                onQueryChanged: (value) => setState(() => _query = value),
                onClearQuery: () => setState(() {
                  _searchController.clear();
                  _query = '';
                }),
                onSelect: (key, rowTitle) => _selectSection(
                  key,
                  isMobile: false,
                  rowTitle: rowTitle,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const HostSettingsNotice(),
                    SettingsScopeNotice(section: _selected),
                    Expanded(
                      child: SettingsFormScope(
                        isMobile: false,
                        authority: ref.watch(backendProvider),
                        child: SettingsRowHighlight(
                          rowTitle: _highlightRow,
                          child:
                              Builder(builder: _selectedSection(groups).build),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
