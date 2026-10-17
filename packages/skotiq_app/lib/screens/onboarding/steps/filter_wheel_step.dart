import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/utils/confirm_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'device_picker_step.dart';

/// Filter wheel selection + filter-name editing.
///
/// Optional — many imagers run mono-OSC setups without a filter wheel.
/// When a wheel is picked we connect it and read its ACTUAL slot count +
/// driver-reported filter names, so an 8-position ZWO EFW shows eight editable
/// rows (not a hardcoded default). Names the user already typed are preserved
/// for the slots they cover. If the wheel can't be connected we fall back to
/// the existing draft/last-resort editor rather than fabricating a count.
/// Merge the driver's actual filter-slot names with names the user already
/// typed in the onboarding draft. The result ALWAYS has exactly
/// [driverNames.length] entries (the wheel's real slot count), and keeps a
/// user-entered name for any slot they already filled in — otherwise it uses
/// the driver-reported name for that slot. Pure + [visibleForTesting] so the
/// "use the device count, preserve user names" rule is unit-tested directly.
@visibleForTesting
List<String> mergeFilterSlotNames(
  List<String> driverNames,
  List<String> draftNames,
) {
  return List<String>.generate(
    driverNames.length,
    (i) => i < draftNames.length && draftNames[i].trim().isNotEmpty
        ? draftNames[i]
        : driverNames[i],
  );
}

class OnboardingFilterWheelStep extends ConsumerStatefulWidget {
  const OnboardingFilterWheelStep({super.key});

  @override
  ConsumerState<OnboardingFilterWheelStep> createState() =>
      _OnboardingFilterWheelStepState();
}

class _OnboardingFilterWheelStepState
    extends ConsumerState<OnboardingFilterWheelStep> {
  // Last-resort fallback ONLY when a wheel's real slot count can't be read
  // (connect failed AND the draft carries no prior names). The happy path
  // reads the actual slot count + names from the connected driver.
  static const int _fallbackSlots = 5;

  /// Width of the slot-number gutter beside each filter field.
  static const double _slotNumberWidth = 32;

  /// Upper bound used ONLY when the wheel's real position count is unknown.
  /// A connected wheel caps the editor at what it actually reports.
  static const int _hardSlotCap = 12;

  List<TextEditingController> _controllers = [];

  /// True while we connect the just-picked wheel to read its real slot count
  /// and driver-reported filter names.
  bool _loadingSlots = false;

  @override
  void initState() {
    super.initState();
    final draft = ref.read(onboardingDraftProvider);
    final draftNames = draft.filterNames;
    _rebuildControllers(
      count: draftNames.isNotEmpty ? draftNames.length : _fallbackSlots,
      names: draftNames,
    );
    // Re-entering the step with a wheel already picked but no names on record
    // (an earlier visit whose connect failed) rendered the fallback slots
    // without ever saving them. Adopt what is displayed so the profile carries
    // the filters the user was shown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (draft.filterWheelId == null) return;
      _commitFiltersIfUnset();
    });
  }

  /// Commit the on-screen slot names when the draft carries none.
  ///
  /// Only when the draft is empty: the driver-reported names take precedence,
  /// and a user-typed name must never be replaced by a `Filter N` placeholder.
  void _commitFiltersIfUnset() {
    if (ref.read(onboardingDraftProvider).filterNames.isNotEmpty) return;
    _commitFilters();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _rebuildControllers({required int count, required List<String> names}) {
    for (final c in _controllers) {
      c.dispose();
    }
    _controllers = List.generate(
      count,
      (i) => TextEditingController(
        text: i < names.length && names[i].trim().isNotEmpty
            ? names[i]
            : 'Filter ${i + 1}',
      ),
    );
  }

  /// Connect the picked filter wheel and seed the slot editor from the driver's
  /// ACTUAL slot count + reported names (e.g. an 8-position ZWO EFW shows eight
  /// slots, not the fallback). Names the user already entered in the draft are
  /// preserved for the slots they cover. Best-effort: a failed connect leaves
  /// the current editor intact — the real count is re-read when the wheel
  /// connects later in the normal equipment flow.
  Future<void> _seedSlotsFromDevice(String deviceId) async {
    setState(() => _loadingSlots = true);
    try {
      await ref
          .read(filterWheelStateProvider.notifier)
          .connect(deviceId, maxRetries: 1);
      if (!mounted) return;
      final fw = ref.read(filterWheelStateProvider);
      final driverNames = fw.filterNames;
      if (fw.connectionState == DeviceConnectionState.connected &&
          driverNames.isNotEmpty) {
        final draftNames = ref.read(onboardingDraftProvider).filterNames;
        final seeded = mergeFilterSlotNames(driverNames, draftNames);
        if (!mounted) return;
        setState(() => _rebuildControllers(
              count: seeded.length,
              names: seeded,
            ));
        _commitFilters();
      }
    } catch (e) {
      // Surface for diagnostics but don't block onboarding on a flaky connect.
      developer.log(
        'Filter wheel slot read failed for $deviceId: $e',
        name: 'OnboardingFilterWheelStep',
        level: 900,
      );
    } finally {
      if (mounted) {
        setState(() => _loadingSlots = false);
        // The editor only reached the draft when the user typed in it, so a
        // wheel whose slot count could not be read showed a column of named,
        // apparently-saved slots and then created a profile with no filters at
        // all — the sequencer's filter list came up empty on the first night.
        // Commit what is on screen whenever the draft still has nothing, so the
        // profile matches the slots the step displayed. Deliberately after the
        // driver merge, and only when the draft is empty, so real driver names
        // are never overwritten by the "Filter N" placeholders.
        _commitFiltersIfUnset();
      }
    }
  }

  void _commitFilters() {
    final names = _controllers
        .map((c) => c.text.trim().isNotEmpty
            ? c.text.trim()
            : 'Slot ${_controllers.indexOf(c) + 1}')
        .toList();
    ref.read(onboardingDraftProvider.notifier).setFilterNames(names);
  }

  /// Add a slot back, recovering the wheel's own name for that position.
  ///
  /// A placeholder like "Filter 7" is a name nobody typed and no wheel reports,
  /// and it travels into FITS headers, flat matching and per-filter focus
  /// offsets. The connected wheel already reports what sits at that position;
  /// when it has not, the row opens blank so the user names it.
  void _addSlot() {
    final driverNames = ref.read(filterWheelStateProvider).filterNames;
    final index = _controllers.length;
    final recovered = index < driverNames.length ? driverNames[index] : '';
    setState(() {
      _controllers.add(TextEditingController(text: recovered));
    });
    _commitFilters();
  }

  /// Delete a slot, confirming first when it is not the LAST row.
  ///
  /// Slot labels are positions on the wheel, so removing a middle row shifts
  /// every row below it up one position — the name the user typed for
  /// position 5 silently becomes position 4, and per-filter focus offsets keyed
  /// by position follow it. Deleting the last row cannot renumber anything, so
  /// it stays a single click.
  Future<void> _removeSlot(int index) async {
    final isLast = index == _controllers.length - 1;
    if (!isLast) {
      final name = _controllers[index].text.trim();
      final confirmed = await ConfirmDialog.show(
        context: context,
        title: 'Remove this slot?',
        message:
            'Removing slot ${index + 1}${name.isEmpty ? '' : ' ($name)'} moves '
            'every slot below it up one position, so the filters after it will '
            'no longer sit on the positions you gave them.',
        confirmLabel: 'Remove slot',
        isDestructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    setState(() {
      _controllers[index].dispose();
      _controllers.removeAt(index);
    });
    _commitFilters();
  }

  /// Positions the CONNECTED wheel reports, or null when we have no reading.
  ///
  /// Only trusted when the connected device is the one the draft picked: a
  /// stale connection to another wheel must not cap this one's editor.
  int? _reportedSlotCount(OnboardingDraft draft, FilterWheelState wheel) {
    if (draft.filterWheelId == null) return null;
    if (wheel.connectionState != DeviceConnectionState.connected) return null;
    if (wheel.deviceId != draft.filterWheelId) return null;
    return wheel.filterNames.isEmpty ? null : wheel.filterNames.length;
  }

  /// The line under the Filters header: what the wheel reports, and — at the
  /// cap — why there is nothing left to add. The reason has to be on screen
  /// rather than in a tooltip, because the control it explains is now gone.
  String _slotCountCaption({
    required OnboardingDraft draft,
    required int? reportedSlots,
    required bool atSlotCap,
  }) {
    final wheel = draft.filterWheelName ?? 'This wheel';
    if (!atSlotCap) return '$wheel reports $reportedSlots positions.';
    if (reportedSlots != null) {
      return 'All $reportedSlots positions on this wheel are listed — '
          '$wheel has no slot ${reportedSlots + 1} to hold another filter.';
    }
    return 'A profile can hold at most $_hardSlotCap filters.';
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(onboardingDraftProvider);
    final notifier = ref.read(onboardingDraftProvider.notifier);
    final colors = SkotiqColors.of(context);
    final hasWheel = draft.filterWheelId != null;

    // The wheel's own position count is the cap. Inventing slot 8 on a
    // 7-position wheel produced a profile whose filter list the hardware can
    // never reach — the sequencer would ask for a position that does not exist.
    // With no reading (connect failed) fall back to the generic hard cap.
    final reportedSlots =
        _reportedSlotCount(draft, ref.watch(filterWheelStateProvider));
    final slotCap = reportedSlots ?? _hardSlotCap;
    final atSlotCap = _controllers.length >= slotCap;

    final viewportHeight = MediaQuery.sizeOf(context).height;
    final pickerHeight = hasWheel
        ? panelWidthFromFraction(
            viewportHeight,
            fraction: 0.28,
            min: 180,
            max: 240,
          )
        : panelWidthFromFraction(
            viewportHeight,
            fraction: 0.45,
            min: 240,
            max: 380,
          );

    // Scrollable: a 12-slot wheel plus the picker exceeds the panel in a short
    // window, and as a bare Column the surplus overflowed instead of scrolling.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // Picker takes a viewport-fraction so the filter editor below has
            // breathing room when the wheel is selected.
            height: pickerHeight,
            child: OnboardingDevicePickerBody(
              title: 'Pick your filter wheel (optional)',
              subtitle:
                  'Tell us what each slot holds so flats, autofocus, and offsets work per filter.',
              icon: SkotiqIcons.filterWheel,
              deviceType: DeviceType.filterWheel,
              selectedDeviceId: draft.filterWheelId,
              selectedDeviceName: draft.filterWheelName,
              allowSkip: true,
              onSelected: (device) {
                notifier.setFilterWheel(
                  id: device.activeDeviceId,
                  name: device.displayName,
                );
                setState(() {});
                // Connect the wheel and read its real slot count + filter names
                // so the editor reflects the hardware (e.g. 8 slots), not a
                // hardcoded default.
                _seedSlotsFromDevice(device.activeDeviceId);
              },
              onCleared: () {
                notifier.setFilterWheel(id: '');
                setState(() {});
              },
            ),
          ),
          if (hasWheel) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            SectionTitle(
              icon: SkotiqIcons.filterWheel,
              title: 'Filters',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loadingSlots) ...[
                    SizedBox(
                      width: SkotiqTokens.iconXs,
                      height: SkotiqTokens.iconXs,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Text(
                      'Reading wheel…',
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                  ],
                  // At the cap there is no button at all.
                  //
                  // A disabled control still reads as a control, and the
                  // accessibility tree publishes it as a plain button with a tap
                  // action — so pressing "Add slot" on a full wheel gives no row,
                  // no toast and no message. A wheel with seven positions has no
                  // eighth to add, ever. Say that, and offer nothing to press.
                  if (atSlotCap)
                    Text(
                      reportedSlots != null
                          ? 'Wheel is full'
                          : 'Filter limit reached',
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textMuted,
                      ),
                    )
                  else
                    SkotiqButton(
                      icon: SkotiqIcons.add,
                      label: 'Add slot',
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      onPressed: _loadingSlots ? null : _addSlot,
                    ),
                ],
              ),
            ),
            if (atSlotCap || reportedSlots != null) ...[
              Padding(
                padding: const EdgeInsets.only(
                  bottom: SkotiqTokens.spaceSm,
                ),
                child: Text(
                  _slotCountCaption(
                    draft: draft,
                    reportedSlots: reportedSlots,
                    atSlotCap: atSlotCap,
                  ),
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ),
            ],
            // List of editable filter slots. We deliberately render inline
            // (not in a separate Drift table) so the user sees their
            // changes saved on Next without needing to confirm a sub-form.
            ...List.generate(_controllers.length, (i) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: SkotiqTokens.spaceXs,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: _slotNumberWidth,
                      child: Text(
                        '${i + 1}',
                        style: SkotiqTypography.readoutSm.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SkotiqTextField(
                        controller: _controllers[i],
                        hint: 'L / R / G / B / Ha …',
                        onChanged: (_) => _commitFilters(),
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    SkotiqIconButton(
                      icon: SkotiqIcons.delete,
                      tooltip: 'Remove slot ${i + 1}',
                      size: IconButtonSize.sm,
                      color: colors.error,
                      onPressed:
                          _controllers.length > 1 ? () => _removeSlot(i) : null,
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}
