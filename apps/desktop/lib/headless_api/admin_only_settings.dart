import 'dart:io' show HttpStatus;

import 'package:shelf/shelf.dart';
import 'package:skotiq_core/settings.dart' show AdminOnly;

import 'request_context.dart';
import 'validation.dart';

/// The `code` of the 403 that refuses a change to a setting declared
/// [reason], and what one such setting is and several are, in its message.
({String code, String one, String many}) _refusal(AdminOnly reason) =>
    switch (reason) {
      AdminOnly.credential => (
        code: 'credential_setting',
        one: 'holds a credential',
        many: 'hold credentials',
      ),
      AdminOnly.credentialTarget => (
        code: 'credential_setting',
        one: 'says where the imaging computer sends a credential',
        many: 'say where the imaging computer sends its credentials',
      ),
      AdminOnly.hostProgram => (
        code: 'host_program_setting',
        one: 'decides which program the imaging computer runs',
        many: 'decide which programs the imaging computer runs',
      ),
      AdminOnly.administration => (
        code: 'admin_setting',
        one:
            "belongs to the imaging computer's backups, download source or "
            'remote access',
        many:
            "belong to the imaging computer's backups, download source or "
            'remote access',
      ),
    };

/// The `code` of the 403 for a setting declared [reason].
String adminOnlyRefusalCode(AdminOnly reason) => _refusal(reason).code;

/// Refuses a request changing [settings], each named with why the settings
/// catalog keeps it for admin links, unless the request has admin access.
void refuseAdminOnlyChange(Request request, Map<String, AdminOnly> settings) {
  if (settings.isEmpty || requestHasAdminAccess(request)) return;
  final reason = AdminOnly.values.firstWhere(settings.containsValue);
  final names = [
    for (final MapEntry(:key, :value) in settings.entries)
      if (value == reason) key,
  ]..sort();
  final single = names.length == 1;
  final refusal = _refusal(reason);
  throw HandlerFailure(
    code: refusal.code,
    statusCode: HttpStatus.forbidden,
    message:
        '${names.join(', ')} ${single ? refusal.one : refusal.many}, which '
        'only a link with admin access can change. Change '
        '${single ? 'it' : 'them'} on the imaging computer, or link with '
        'admin access.',
    details: {'settings': names, 'requiredLevel': 'admin'},
  );
}
