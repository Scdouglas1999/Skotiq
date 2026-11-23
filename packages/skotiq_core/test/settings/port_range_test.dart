import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/settings.dart';

void main() {
  test('any port is 1 to 65535; the web server takes 1024 up', () {
    expect(PortRange.any.contains(0), isFalse);
    expect(PortRange.any.contains(1), isTrue);
    expect(PortRange.any.contains(65535), isTrue);
    expect(PortRange.any.contains(65536), isFalse);
    expect(PortRange.webServer.contains(1023), isFalse);
    expect(PortRange.webServer.contains(1024), isTrue);
    expect(PortRange.webServer.contains(65535), isTrue);
    expect(PortRange.webServer.contains(65536), isFalse);
  });
}
