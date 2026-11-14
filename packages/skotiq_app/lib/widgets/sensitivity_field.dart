import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The exposure-sensitivity control of a form.
///
/// For a gain camera it is the surface's own gain field ([gainField]),
/// unchanged. For a DSLR or mirrorless body it is a picker of the speeds the
/// connected camera offers, labeled in ISO. The decision is made here from
/// the camera's [ExposureSensitivity], so no form tests what kind of camera
/// is connected.
///
/// [value] is the stored gain number (the ISO speed for a DSLR); a value the
/// body does not offer shows as the speed the camera would take for it. A
/// null [value] shows [unsetHint] (a step that takes the profile's default).
class SensitivityField extends ConsumerWidget {
  const SensitivityField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.gainField,
    this.sensitivity,
    this.unsetHint,
    this.dense = false,
    this.labelled = false,
    this.isoField,
  });

  final int? value;
  final ValueChanged<int> onChanged;

  /// The form's own ISO control, for a form whose rows put the label beside
  /// the control; the plain [IsoSpeedPicker] when null.
  final Widget Function(BuildContext context, IsoSensitivity iso)? isoField;

  /// Each speed reads "ISO 800" rather than "800", for a control that has
  /// no label of its own beside it.
  final bool labelled;

  /// The form's gain field, used as it is for a gain camera.
  final WidgetBuilder gainField;

  /// The sensitivity to offer; the connected imaging camera's when null.
  final ExposureSensitivity? sensitivity;

  final String? unsetHint;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ExposureSensitivity current =
        sensitivity ?? ref.watch(cameraSensitivityProvider);
    return switch (current) {
      GainSensitivity() => gainField(context),
      IsoSensitivity() when isoField != null => isoField!(context, current),
      IsoSensitivity() => IsoSpeedPicker(
          sensitivity: current,
          value: value,
          onChanged: onChanged,
          unsetHint: unsetHint,
          dense: dense,
          labelled: labelled,
        ),
    };
  }
}

/// A picker of a DSLR or mirrorless body's ISO speeds.
class IsoSpeedPicker extends StatelessWidget {
  const IsoSpeedPicker({
    super.key,
    required this.sensitivity,
    required this.value,
    required this.onChanged,
    this.unsetHint,
    this.dense = false,
    this.labelled = false,
  });

  final IsoSensitivity sensitivity;
  final int? value;
  final ValueChanged<int> onChanged;
  final String? unsetHint;
  final bool dense;
  final bool labelled;

  @override
  Widget build(BuildContext context) {
    final speeds = [for (final s in sensitivity.speeds) '$s'];
    final shown = value == null ? null : '${sensitivity.accept(value!)}';
    return Semantics(
      label: 'ISO',
      value: shown,
      child: SkotiqDropdown(
        value: shown,
        hint: unsetHint ?? 'Choose ISO',
        items: speeds,
        itemLabels: labelled
            ? [for (final s in sensitivity.speeds) sensitivity.describe(s)]
            : null,
        isExpanded: true,
        dense: dense,
        onChanged: (picked) {
          final speed = int.tryParse(picked ?? '');
          if (speed != null) onChanged(speed);
        },
      ),
    );
  }
}
