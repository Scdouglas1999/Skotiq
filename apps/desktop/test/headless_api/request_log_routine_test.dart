// A linked client's polling filled the host's log with two lines per read
// (qa-rig RIG-04/RIG-20: 68 to 80 MB a day). Prompt successful reads are not
// logged; writes, failures and slow requests are.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

void main() {
  test('a prompt successful read is routine', () {
    expect(
      requestCompletionIsRoutine(method: 'GET', statusCode: 200, elapsedMs: 3),
      isTrue,
    );
  });

  test('writes, failures and slow reads are logged', () {
    expect(
      requestCompletionIsRoutine(method: 'POST', statusCode: 200, elapsedMs: 3),
      isFalse,
    );
    expect(
      requestCompletionIsRoutine(method: 'GET', statusCode: 404, elapsedMs: 3),
      isFalse,
    );
    expect(
      requestCompletionIsRoutine(
        method: 'GET',
        statusCode: 200,
        elapsedMs: 5000,
      ),
      isFalse,
    );
  });
}
