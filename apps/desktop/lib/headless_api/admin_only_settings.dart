import 'dart:io' show HttpStatus;

import 'package:shelf/shelf.dart';

import 'request_context.dart';
import 'validation.dart';

/// Settings a linked client paired the ordinary way may not change: the host
/// takes them only from a request with admin access.
enum AdminOnlySetting {
  /// Holds a credential the host signs in with (`Setting.credential`).
  credential(
    code: 'credential_setting',
    one: 'holds a credential',
    many: 'hold credentials',
  ),

  /// Names a program or script the host runs (`Setting.runsOnHost`).
  hostProgram(
    code: 'host_program_setting',
    one: 'names a program the imaging computer runs',
    many: 'name programs the imaging computer runs',
  );

  const AdminOnlySetting({
    required this.code,
    required this.one,
    required this.many,
  });

  /// The `code` of the 403 refusal.
  final String code;

  /// What one such setting is, and what several are, in the refusal.
  final String one;
  final String many;

  /// Refuses a request changing [settings] unless it has admin access.
  void refuseChange(Request request, List<String> settings) {
    if (settings.isEmpty || requestHasAdminAccess(request)) return;
    final names = [...settings]..sort();
    final single = names.length == 1;
    throw HandlerFailure(
      code: code,
      statusCode: HttpStatus.forbidden,
      message:
          '${names.join(', ')} ${single ? one : many}, which only a link '
          'with admin access can change. Change ${single ? 'it' : 'them'} on '
          'the imaging computer, or link with admin access.',
      details: {'settings': names, 'requiredLevel': 'admin'},
    );
  }
}
