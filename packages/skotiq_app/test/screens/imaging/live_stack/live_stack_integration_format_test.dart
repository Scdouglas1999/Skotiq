import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_stack/live_stack_formatters.dart';

// The live stack's integration readout is DurationFormat's short style: a
// positive time never reads "0s", and nothing stacked reads an em dash.
void main() {
  test('integration readout', () {
    expect(formatLiveIntegration(0), '—');
    expect(formatLiveIntegration(double.nan), '—');
    expect(formatLiveIntegration(0.4), '1s');
    expect(formatLiveIntegration(45), '45s');
    expect(formatLiveIntegration(123), '2m 3s');
    expect(formatLiveIntegration(120), '2m');
    expect(formatLiveIntegration(3720), '1h 2m');
    expect(formatLiveIntegration(7200), '2h');
  });
}
