part of '../analytics_screen.dart';

/// The layout width one header action occupies.
///
/// Material gives every [IconButton] a 48-pixel tap target whatever its glyph
/// measures, so this is what the header has to budget per control — not the
/// 18-pixel icon inside it.
const double _kSessionHeaderActionExtent = 48;

/// The narrowest the session name and its date may be squeezed before the
/// action cluster has to fold into a menu.
///
/// Below this the title ellipsizes to a word or two and the header stops
/// naming the session it belongs to, which is the one thing a dialog header
/// exists to do.
const double _kSessionHeaderTitleMinWidth = 180;

/// The one sentence this dialog's Session Review actions refuse a remote client
/// with.
///
/// The same fact the screen itself states when it is reached by deep link
/// ("Open Session Review on the imaging host"), said on the control instead of
/// on the far side of a navigation.
const String _kSessionReviewHostOnlyRefusal =
    'Session Review works on the imaging host, where the full-resolution subs '
    'and the integrated masters are stored. Open Skotiq there to review '
    'this night.';

/// One session-dialog header action: what it is called, what it does, and the
/// glyph that stands for it.
///
/// Modelled rather than built inline because the same actions have to paint
/// EITHER as icons in the header OR as rows in an overflow menu, and a control
/// that exists in only one of the two forms is a control the accessibility tree
/// and the screen disagree about.
class _SessionHeaderAction {
  const _SessionHeaderAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.unavailableReason,
    this.buttonKey,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// Why this machine cannot run the action, or null when it can.
  ///
  /// Non-null disables the control — inline button and menu row alike — and
  /// goes into its accessible NAME as well as its tooltip, so the refusal is
  /// readable BEFORE the press by whoever is reading. A control that looks
  /// live and refuses afterwards teaches the operator that the app's enabled
  /// state means nothing, which is the shape `darkroom_navigation.dart` names
  /// as the defect it fixed.
  ///
  /// The name, not the tooltip alone: these buttons are icon-only, so a
  /// tooltip is the ONLY place a pointer user can read the reason — and the
  /// only place anybody else cannot. The Linux AT-SPI bridge does not fold
  /// `SemanticsProperties.tooltip` into the accessible name, so a screen
  /// reader was handed `Refine on imaging host [DISABLED]` and no reason at
  /// all. [unavailableControlName] composes the two.
  final String? unavailableReason;

  /// Identifies the inline icon button; the menu row carries no key because it
  /// only exists while the menu is open.
  final Key? buttonKey;

  /// True when the action can run on this machine.
  bool get available => unavailableReason == null;
}

/// What the culling decided about a session's LIGHT frames.
///
/// Counted from `captured_images.is_accepted`, the one place the verdict is
/// recorded — the same source `/api/sessions` reads for its
/// `acceptedLights` / `rejectedLights` pair, so the dialog and the API cannot
/// disagree about the same night.
///
/// Calibration frames are excluded because they are never graded: counting them
/// would inflate `accepted` with darks and flats nobody culled.
class _SessionGrading {
  const _SessionGrading({required this.accepted, required this.rejected});

  final int accepted;
  final int rejected;

  static _SessionGrading of(List<DbCapturedImage> images) {
    var accepted = 0;
    var rejected = 0;
    for (final image in images) {
      if (image.frameType != 'light') continue;
      if (image.isAccepted) {
        accepted++;
      } else {
        rejected++;
      }
    }
    return _SessionGrading(accepted: accepted, rejected: rejected);
  }
}

/// Gap between two of the detail dialog's [Readout]s.
const double _dialogStatGap = 24;

class _SessionDetailDialog extends ConsumerStatefulWidget {
  final ImagingSession session;

  const _SessionDetailDialog({required this.session});

  @override
  ConsumerState<_SessionDetailDialog> createState() =>
      _SessionDetailDialogState();
}

class _SessionDetailDialogState extends ConsumerState<_SessionDetailDialog> {
  ImagingSession get session => widget.session;

  /// Why the action the operator just pressed could not do what it offered.
  ///
  /// It is held HERE, and painted inside the dialog, because the dialog is what
  /// stays up to carry it. Posted to the page's `ScaffoldMessenger` instead,
  /// the sentence renders under this modal route: at every window width narrow
  /// enough for the dialog to cover the SnackBar the operator read a refusal
  /// with its first half hidden — "…t. Integrate it in Session Review" — and at
  /// phone width only the last two words survived.
  String? _refusal;

  void _refuse(String reason) {
    if (!mounted) return;
    setState(() => _refusal = reason);
  }

  /// Run [action], dropping whatever the LAST action had to say first.
  ///
  /// A refusal is about the press that produced it. Left standing over the next
  /// press it becomes a sentence about a control the operator has moved on
  /// from — the alert would still read "this session has no integrated master"
  /// while a CSV export was busy underneath it.
  void _invoke(_SessionHeaderAction action) {
    if (_refusal != null) setState(() => _refusal = null);
    action.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final imagesAsyncValue = ref.watch(dbSessionImagesProvider(session.id));
    // The client ROLE, not the connection. `backend is NetworkBackend` is a
    // CONNECTION fact: a desktop launched with `--remote-host` that has not
    // reached its rig is `Disconnected`, so that test read false for the whole
    // pre-handshake window and after every drop — and during exactly that
    // window this dialog kept its host-capable labels, "Refine in Darkroom"
    // explained itself only after the press, and "Review & integrate" did not
    // refuse at all: it popped the dialog and landed the operator on the
    // Session Review host-only wall. Both actions ask the same question every
    // other Darkroom entry point asks, in the words
    // `darkroom_navigation.dart` shares.
    //
    // The Darkroom action asks BOTH of its questions here: the role, and
    // whether this night has a master to open at all. The second used to be
    // asked only inside the tap handler, so a session whose frames were all
    // rejected drew "Refine in Darkroom" live and answered "this session has no
    // integrated master yet" after the press — the same cry-wolf shape the role
    // refusal was moved onto the control to end.
    final darkroomHostRefusal = watchDarkroomHostOnlyRefusal(ref);
    final darkroomRefusal = watchDarkroomSessionRefusal(ref, session.id);
    final reviewRefusal = ref.watch(isRemoteClientProvider)
        ? _kSessionReviewHostOnlyRefusal
        : null;
    final l10n = context.l10n;
    final actions = _headerActions(
      darkroomHostRefusal: darkroomHostRefusal,
      darkroomRefusal: darkroomRefusal,
      reviewRefusal: reviewRefusal,
      l10n: l10n,
    );
    final refusal = _refusal;

    return Dialog(
      backgroundColor: colors.surface,
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 600,
          designMaxHeight: 700,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // A Row hands its children unbounded width, so a cluster of
                  // icon buttons beside a title does not shrink — the ones that
                  // run past the end are clipped away while the accessibility
                  // tree still advertises every one of them, and a tap on the
                  // space where one used to be lands on nothing. Below the
                  // width where the whole cluster and a readable title both
                  // fit, they fold into a single overflow menu, so what the
                  // tree reports is what paints.
                  //
                  // Close is not in that menu: it is how this modal is
                  // dismissed, not one of the things it does.
                  final inlineExtent =
                      (actions.length + 1) * _kSessionHeaderActionExtent;
                  final inline = constraints.maxWidth - inlineExtent >=
                      _kSessionHeaderTitleMinWidth;
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              session.name ??
                                  l10n.text('analyticsUnnamedSession'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: SkotiqTypography.sectionTitle.copyWith(
                                color: colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              DateFormat('MMM d, yyyy HH:mm')
                                  .format(session.startTime),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: SkotiqTypography.bodySm.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (inline)
                        for (final action in actions)
                          _headerAction(
                            key: action.buttonKey,
                            icon: action.icon,
                            label: action.label,
                            onPressed:
                                action.available ? () => _invoke(action) : null,
                            tooltip: action.unavailableReason ?? action.label,
                            unavailableReason: action.unavailableReason,
                          )
                      else
                        _headerOverflowMenu(colors, actions),
                      _headerAction(
                        key: const ValueKey('session_detail_close'),
                        icon: LucideIcons.x,
                        label: l10n.text('commonClose'),
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: l10n.text('commonClose'),
                      ),
                    ],
                  );
                },
              ),
            ),

            // The refusal an action just returned, inside the route that
            // carries it rather than under it.
            if (refusal != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  SkotiqTokens.spaceLg,
                  SkotiqTokens.spaceLg,
                  SkotiqTokens.spaceLg,
                  0,
                ),
                child: SkotiqBanner(
                  key: const ValueKey('session_detail_refusal'),
                  title: refusal,
                  onDismiss: () => setState(() => _refusal = null),
                ),
              ),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Statistics
                    _buildStatisticsSection(
                      context,
                      colors,
                      imagesAsyncValue,
                    ),
                    const SizedBox(height: SkotiqTokens.spaceLg),

                    // Images
                    imagesAsyncValue.when(
                      data: (images) =>
                          _buildImagesSection(context, colors, images),
                      loading: () => const _AnalyticsLoading(
                        height: kAnalyticsThumbnailRailHeight,
                      ),
                      error: (err, stack) => _AnalyticsError(
                        title: 'Frames did not load',
                        message: err.toString(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Everything this dialog can do to the session, in header order.
  ///
  /// The closures reach for `State.context`, not a context handed in: the
  /// Darkroom action resolves the night's masters before it decides, and only a
  /// `mounted` check on this State guards the context it uses on the far side
  /// of that await.
  List<_SessionHeaderAction> _headerActions({
    required String? darkroomHostRefusal,
    required String? darkroomRefusal,
    required String? reviewRefusal,
    required SkotiqLocalizations l10n,
  }) {
    return [
      // Open the Session Review / Morning Report (cull + integrate).
      _SessionHeaderAction(
        buttonKey: const ValueKey('session_detail_review'),
        icon: LucideIcons.sparkles,
        label: reviewRefusal == null
            ? 'Review & integrate'
            : 'Review on imaging host',
        unavailableReason: reviewRefusal,
        onPressed: () {
          Navigator.of(context).pop();
          context.push('/session-review?session=${session.id}');
        },
      ),
      // Open the night's linear master in the Darkroom. Both refusals are
      // already on the control; the resolve below is what a press acts on.
      //
      // The LABEL follows the role alone. "Refine on imaging host" names where
      // the action lives, which is true of a client and false of a night this
      // machine simply never integrated — that night's control keeps its own
      // name and carries the reason.
      _SessionHeaderAction(
        buttonKey: const ValueKey('session_detail_darkroom'),
        icon: LucideIcons.sliders,
        label: darkroomHostRefusal == null
            ? 'Refine in Darkroom'
            : 'Refine on imaging host',
        unavailableReason: darkroomRefusal,
        onPressed: () async {
          // Resolve BEFORE dismissing, and resolve again rather than trusting
          // the answer the control was built with: the two are separated by
          // however long the dialog stood open, and only a master that is
          // there NOW earns the pop. A session that lost its master in that
          // window leaves the dialog up to carry the explanation.
          final target = await resolveDarkroomTargetForSession(
            ref,
            session.id,
          );
          if (!mounted) return;
          final masterId = target.masterId;
          if (masterId == null) {
            // The control was built on an older read of the same night, so it
            // is re-read here: the sentence and the control it sits under must
            // not disagree about whether there is a master.
            ref.invalidate(darkroomSessionTargetProvider(session.id));
            _refuse(target.unavailableReason!);
            return;
          }
          Navigator.of(context).pop();
          openDarkroomForMaster(context, masterId);
        },
      ),
      // View the rich Feature-A session report.
      _SessionHeaderAction(
        icon: LucideIcons.fileBarChart,
        label: 'Session report',
        onPressed: () => SessionReportDialog.show(context, session.id),
      ),
      // Export buttons
      _SessionHeaderAction(
        icon: LucideIcons.fileJson,
        label: l10n.text('analyticsExportJson'),
        onPressed: () => _exportJson(context, ref),
      ),
      _SessionHeaderAction(
        icon: LucideIcons.fileSpreadsheet,
        label: l10n.text('analyticsExportCsv'),
        onPressed: () => _exportCsv(context, ref),
      ),
      _SessionHeaderAction(
        icon: LucideIcons.fileText,
        label: l10n.text('analyticsExportHtml'),
        onPressed: () => _exportReport(context, ref),
      ),
      // Share only exists where the OS has a share sheet. On desktop
      // `shareXFiles()` is unimplemented, and the CSV button beside it already
      // writes the same file and shows its path.
      if (Platform.isAndroid || Platform.isIOS)
        _SessionHeaderAction(
          icon: LucideIcons.share,
          label: l10n.text('share'),
          onPressed: () => _exportAndShare(context, ref),
        ),
    ];
  }

  /// The folded form of the action cluster.
  ///
  /// One button that names itself, and the same actions as named rows once it
  /// is opened — so a control is either painted and in the tree, or in neither.
  Widget _headerOverflowMenu(
    SkotiqColors colors,
    List<_SessionHeaderAction> actions,
  ) {
    return PopupMenuButton<_SessionHeaderAction>(
      key: const ValueKey('session_detail_actions_menu'),
      icon: const Icon(
        LucideIcons.moreVertical,
        size: 18,
        semanticLabel: 'Session actions',
      ),
      tooltip: 'Session actions',
      onSelected: _invoke,
      itemBuilder: (context) => [
        for (final action in actions)
          PopupMenuItem<_SessionHeaderAction>(
            value: action,
            // A row this machine cannot run is disabled here as well as inline,
            // so the folded header and the unfolded one publish the same
            // states — and it carries the same reason, in the same two places:
            // the accessible name, and a tooltip for the pointer. The folded
            // header used to be the one place the refusal existed nowhere at
            // all: no tooltip was hung on it, and the row's visible label only
            // says where the action lives.
            enabled: action.available,
            child: _headerMenuRow(colors, action),
          ),
      ],
    );
  }

  /// One row of the folded header: the action's glyph and name, and — when
  /// this machine cannot run it — the reason, in the name and in a tooltip.
  ///
  /// [PopupMenuItem] wraps its child in `MergeSemantics`, so the annotation
  /// added here folds into the row's own button node: the name it publishes is
  /// the composed sentence and the row stays ONE node with the enabled state
  /// [PopupMenuItem] already states. `excludeSemantics` keeps the visible
  /// label from being read a second time inside it.
  Widget _headerMenuRow(SkotiqColors colors, _SessionHeaderAction action) {
    final reason = action.unavailableReason;
    final row = Row(
      children: [
        Icon(
          action.icon,
          size: SkotiqTokens.iconSm,
          color: action.available ? colors.textSecondary : colors.textMuted,
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        // Flexible, not min-sized: a label that grows by a word must wrap
        // inside the menu rather than overflow its row.
        Flexible(
          child: Text(
            action.label,
            style: SkotiqTypography.bodySm.copyWith(
              color: action.available ? colors.textPrimary : colors.textMuted,
            ),
          ),
        ),
      ],
    );
    if (reason == null) return row;
    return Tooltip(
      message: reason,
      child: Semantics(
        label: unavailableControlName(action.label, reason),
        excludeSemantics: true,
        child: row,
      ),
    );
  }

  /// One header action: an icon button that publishes its accessible name,
  /// disabled when [onPressed] is null.
  ///
  /// [tooltip] is the label for an action that can run and the refusal for one
  /// that cannot, which is how the reason reaches a POINTER before the press.
  /// [unavailableReason] is the same sentence again, and it is what reaches
  /// everybody else: the accessible name becomes `<label> — <reason>` so the
  /// refusal is in the one string every reader is handed.
  ///
  /// **An available action names itself on the [Icon].** A Material
  /// [IconButton] wraps itself in `Semantics(container: true, …)`, so an
  /// enclosing `Semantics(label: …)` cannot merge into it: it forms a SECOND
  /// node above the button, and the split publishes a named node with no tap
  /// action over a nameless node that carries the action. `Icon.semanticLabel`
  /// sits inside the button's own node instead, which is why one node comes out
  /// carrying the name, the button role, the enabled state and the tap
  /// together. Before this every one of these buttons published an empty name —
  /// seven anonymous buttons in the header, unreachable by name and
  /// indistinguishable from each other to a screen reader.
  ///
  /// **An unavailable one is renamed from outside instead**, in the shape
  /// `_branch_bar.dart`'s disabled Compare already uses: its own container
  /// node, `enabled: false` stated rather than inferred, and the button's own
  /// semantics excluded so ONE honest node is published rather than two that
  /// disagree. The reason cannot ride on `Icon.semanticLabel` here because the
  /// wrapper has to exclude the icon to keep the name single.
  Widget _headerAction({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    required String tooltip,
    String? unavailableReason,
  }) {
    if (unavailableReason == null) {
      return SkotiqIconButton(
        key: key,
        icon: icon,
        tooltip: tooltip,
        onPressed: onPressed,
      );
    }
    return Semantics(
      container: true,
      button: true,
      enabled: false,
      label: unavailableControlName(label, unavailableReason),
      excludeSemantics: true,
      child: SkotiqIconButton(
        key: key,
        icon: icon,
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  /// The night's numbers. The capture count comes from the session row; the
  /// accepted and rejected split is counted from the frames themselves
  /// (`captured_images.is_accepted`, which [images] carries), which also
  /// covers frames the run's frame watch excluded after grading and sessions
  /// recorded before the row kept that split.
  Widget _buildStatisticsSection(
    BuildContext context,
    SkotiqColors colors,
    AsyncValue<List<DbCapturedImage>> images,
  ) {
    final l10n = context.l10n;
    // Null until the frames have been read: the counts are not claimed from a
    // list that is still loading or failed to load, and the footnote below says
    // so instead of printing a zero that would read as "nothing was rejected".
    final grading = images.whenOrNull(data: _SessionGrading.of);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title: l10n.text('analyticsStatistics')),
        Wrap(
          spacing: _dialogStatGap,
          runSpacing: SkotiqTokens.spaceMd,
          children: [
            _buildStat(
              l10n.text('analyticsTotalExposures'),
              session.totalExposures.toString(),
            ),
            _buildStat(
              l10n.text('analyticsAcceptedLights'),
              grading?.accepted.toString(),
            ),
            _buildStat(
              l10n.text('analyticsRejectedLights'),
              grading?.rejected.toString(),
            ),
            _buildStat(
              l10n.text('analyticsIntegration'),
              (session.totalIntegrationSecs / 3600).toStringAsFixed(2),
              unit: 'h',
            ),
            _buildStat(
              l10n.text('analyticsAvgHfr'),
              session.avgHfr?.toStringAsFixed(2),
              unit: 'px',
            ),
            _buildStat(
              l10n.text('analyticsAvgRms'),
              session.avgGuidingRms?.toStringAsFixed(2),
              // ASCII, not U+2033: the bundled fonts have no prime glyph.
              unit: '"',
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        // These counters come from the session's own light-frame tallies, while
        // the image list below holds every frame written to disk. Unlabelled,
        // "Total Exposures 12" over "Images (16)" reads as one count the app
        // cannot keep straight.
        Text(
          grading == null
              ? l10n.text('analyticsGradingUnread')
              : l10n.text('analyticsExposureCountsLightOnly'),
          style: SkotiqTypography.caption.copyWith(
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  /// One of the night's numbers. A [Readout], so the value leads and the label
  /// sits under it in 11 px muted caps — the pair used to be the other way up,
  /// with the label above a `h5` value.
  Widget _buildStat(String label, String? value, {String? unit}) {
    return Readout(label: label, value: value, unit: unit);
  }

  Widget _buildImagesSection(
    BuildContext context,
    SkotiqColors colors,
    List<DbCapturedImage> images,
  ) {
    final lightCount = images
        .where((image) => image.frameType.toLowerCase() == 'light')
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          title: context.l10n.text(
            'analyticsImages',
            params: {'count': images.length.toString()},
          ),
        ),
        // Says what the list is made of, so it can be compared with the
        // light-only exposure counters above it.
        if (images.isNotEmpty) ...[
          Text(
            context.l10n.text(
              'analyticsFrameMix',
              params: {
                'light': lightCount.toString(),
                'calibration': (images.length - lightCount).toString(),
              },
            ),
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceSm),
        ImageThumbnailStrip(images: images),
      ],
    );
  }

  Future<void> _exportJson(BuildContext context, WidgetRef ref) async {
    try {
      final backend = ref.read(backendProvider);
      if (backend is NetworkBackend) {
        final filePath = await _saveRemoteExport(backend, session.id, 'json');
        if (context.mounted) {
          await revealExportedFile(
            context,
            filePath,
            subject: 'Skotiq session data',
          );
        }
        return;
      }
      final clock = ref.read(clockProvider);
      final exportService = SessionExportService(
        sessionsDao: ref.read(sessionsDaoProvider),
        imagesDao: ref.read(imagesDaoProvider),
        nowProvider: clock.now,
      );

      // The export lands in resolveSkotiqDocumentsDirectory(), which is the
      // private sandbox on Android/iOS — an "Exported to: <path>" line there
      // names a file the user cannot open, so hand it to the share sheet.
      final filePath = await exportService.exportToJson(session.id);

      if (context.mounted) {
        await revealExportedFile(
          context,
          filePath,
          subject: 'Skotiq session data',
        );
      }
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Export failed: $e');
      }
    }
  }

  Future<void> _exportCsv(BuildContext context, WidgetRef ref) async {
    try {
      final backend = ref.read(backendProvider);
      if (backend is NetworkBackend) {
        final filePath = await _saveRemoteExport(backend, session.id, 'csv');
        if (context.mounted) {
          await revealExportedFile(
            context,
            filePath,
            subject: 'Skotiq session data',
          );
        }
        return;
      }
      final clock = ref.read(clockProvider);
      final exportService = SessionExportService(
        sessionsDao: ref.read(sessionsDaoProvider),
        imagesDao: ref.read(imagesDaoProvider),
        nowProvider: clock.now,
      );

      // Same sandbox problem as the JSON export: reveal rather than announce
      // a path the phone user can never reach.
      final filePath = await exportService.exportToCsv(session.id);

      if (context.mounted) {
        await revealExportedFile(
          context,
          filePath,
          subject: 'Skotiq session data',
        );
      }
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Export failed: $e');
      }
    }
  }

  /// Export the session to CSV and hand it to the platform's reachable
  /// destination.
  ///
  /// Routed through [revealExportedFile] — share sheet on Android/iOS, path
  /// snackbar on desktop — because `Share.shareXFiles` is unimplemented on the
  /// shipping desktop build.
  Future<void> _exportAndShare(BuildContext context, WidgetRef ref) async {
    try {
      final backend = ref.read(backendProvider);
      final String filePath;
      if (backend is NetworkBackend) {
        filePath = await _saveRemoteExport(backend, session.id, 'csv');
      } else {
        final clock = ref.read(clockProvider);
        final exportService = SessionExportService(
          sessionsDao: ref.read(sessionsDaoProvider),
          imagesDao: ref.read(imagesDaoProvider),
          nowProvider: clock.now,
        );
        // CSV is the most universal format to hand off.
        filePath = await exportService.exportToCsv(session.id);
      }

      if (!context.mounted) return;
      await revealExportedFile(
        context,
        filePath,
        subject: 'Session data for ${session.name ?? "session"}',
      );
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Export failed: $e');
      }
    }
  }

  Future<void> _exportReport(BuildContext context, WidgetRef ref) async {
    try {
      final backend = ref.read(backendProvider);
      if (backend is NetworkBackend) {
        final filePath = await _saveRemoteExport(backend, session.id, 'html');
        if (context.mounted) {
          await revealExportedFile(
            context,
            filePath,
            subject: 'Skotiq session report',
          );
        }
        return;
      }
      final clock = ref.read(clockProvider);
      final exportService = SessionExportService(
        sessionsDao: ref.read(sessionsDaoProvider),
        imagesDao: ref.read(imagesDaoProvider),
        nowProvider: clock.now,
      );

      final filePath = await exportService.exportToHtml(session.id);

      if (context.mounted) {
        await revealExportedFile(
          context,
          filePath,
          subject: 'Skotiq session report',
        );
      }
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Report export failed: $e');
      }
    }
  }
}

Stream<List<DbCapturedImage>> _pollRemoteSessionImages(
  NetworkBackend backend,
  int sessionId, {
  required Duration interval,
}) =>
    _pollRemoteImages(
      () => _fetchRemoteSessionImages(backend, sessionId),
      interval: interval,
    );

Stream<List<DbCapturedImage>> _pollRemoteStandaloneImages(
  NetworkBackend backend, {
  required Duration interval,
}) =>
    _pollRemoteImages(
      () => _fetchRemoteStandaloneImages(backend),
      interval: interval,
    );

Stream<List<DbCapturedImage>> _pollRemoteImages(
  Future<List<DbCapturedImage>> Function() fetch, {
  required Duration interval,
}) =>
    resilientDistinctPoll(
      fetch: fetch,
      unchanged: listEquals,
      interval: interval,
    );

Future<List<DbCapturedImage>> _fetchRemoteSessionImages(
  NetworkBackend backend,
  int sessionId,
) async {
  final rows = await backend.getSessionImageRows(sessionId);
  return rows.map(DbCapturedImage.fromJson).toList(growable: false);
}

Future<List<DbCapturedImage>> _fetchRemoteStandaloneImages(
  NetworkBackend backend,
) async {
  final rows = await backend.getStandaloneImageRows();
  return rows.map(DbCapturedImage.fromJson).toList(growable: false);
}

Future<String> _saveRemoteExport(
  NetworkBackend backend,
  int sessionId,
  String format,
) async {
  final bytes = await backend.downloadSessionExport(sessionId, format);
  final docsDir = await resolveSkotiqDocumentsDirectory();
  final exportDir = Directory(path.join(docsDir.path, 'Skotiq', 'exports'));
  if (!await exportDir.exists()) {
    await exportDir.create(recursive: true);
  }
  final fileName =
      'session_${sessionId}_${DateTime.now().millisecondsSinceEpoch}.$format';
  final filePath = path.join(exportDir.path, fileName);
  await File(filePath).writeAsBytes(bytes, flush: true);
  return filePath;
}
