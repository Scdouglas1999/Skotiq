import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefKey = 'fujifilm_disclaimer_acknowledged';

bool isFujifilmDevice(String deviceId, String? deviceName) => [
      deviceId,
      if (deviceName != null) deviceName,
    ].any((text) => text.toLowerCase().contains('fuji'));

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

  final result = await _showNotice(context, afterConnect: false);

  if (result == true) {
    await prefs.setBool(_prefKey, true);
    return true;
  }

  return false;
}

/// Asks for the consent a camera's family needs before a connect the
/// operator started: the discovery list, Connect all, a device card's retry.
/// True when the camera needs none or it was given.
Future<bool> askCameraConsentBeforeConnect(
  BuildContext context, {
  required String deviceId,
  String? deviceName,
}) async {
  if (!isFujifilmDevice(deviceId, deviceName)) return true;
  return showFujifilmDisclaimerIfNeeded(context);
}

/// The notice for a Fujifilm camera a connect nobody was asked for brought up
/// (auto-connect at launch): it is connected, so the notice says so and asks
/// nothing. Shown once.
Future<void> showFujifilmNoticeAfterConnect(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_prefKey) == true || !context.mounted) return;
  await _showNotice(context, afterConnect: true);
  await prefs.setBool(_prefKey, true);
}

Future<bool?> _showNotice(BuildContext context, {required bool afterConnect}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final colors = SkotiqColors.of(context);
      return SkotiqDialog(
        title: 'Fujifilm camera control SDK notice',
        width: SkotiqDialog.widthConfirm,
        showCloseButton: false,
        actions: [
          if (!afterConnect)
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
          "${afterConnect ? 'Skotiq connected your Fujifilm camera at startup. ' : ''}"
          "According to Fujifilm's SDK license agreement, using third-party "
          'software to control your Fujifilm camera may void its limited '
          'product warranty. '
          '${afterConnect ? '' : 'By proceeding, you accept that risk.'}\n\n'
          'This notice is not shown again.',
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textSecondary,
          ),
        ),
      );
    },
  );
}
