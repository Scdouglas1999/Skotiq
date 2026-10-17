import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefKey = 'fujifilm_disclaimer_acknowledged';

/// Check if a device ID or name indicates a Fujifilm camera.
bool isFujifilmDevice(String deviceId, String deviceName) {
  final idLower = deviceId.toLowerCase();
  final nameLower = deviceName.toLowerCase();
  return idLower.contains('fujifilm') ||
      idLower.contains('fuji') ||
      nameLower.contains('fujifilm') ||
      nameLower.contains('fuji');
}

/// Shows the Fujifilm warranty disclaimer if not previously acknowledged.
///
/// Returns `true` if the user acknowledged (or already acknowledged previously),
/// `false` if the user cancelled.
Future<bool> showFujifilmDisclaimerIfNeeded(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_prefKey) == true) {
    return true;
  }

  if (!context.mounted) return false;

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final colors = SkotiqColors.of(context);
      return SkotiqDialog(
        title: 'Fujifilm camera control SDK notice',
        width: SkotiqDialog.widthConfirm,
        showCloseButton: false,
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          SkotiqButton(
            label: 'I understand',
            variant: ButtonVariant.primary,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
        child: Text(
          "According to Fujifilm's SDK license agreement, using third-party "
          'software to control your Fujifilm camera may void its limited '
          'product warranty. By proceeding, you accept that risk.\n\n'
          'This notice is not shown again.',
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textSecondary,
          ),
        ),
      );
    },
  );

  if (result == true) {
    await prefs.setBool(_prefKey, true);
    return true;
  }

  return false;
}
