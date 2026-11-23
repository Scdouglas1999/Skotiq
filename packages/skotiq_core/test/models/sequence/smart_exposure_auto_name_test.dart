import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  SmartExposureNode node(String name, List<String> filters) =>
      SmartExposureNode(
        name: name,
        plans: [for (final f in filters) FilterPlan(filterName: f)],
      );

  test('the builder name lists the filters in plan order', () {
    expect(
      SmartExposureNode.autoName(['Ha', 'OIII', 'SII']),
      'Smart Exposure: Ha+OIII+SII',
    );
  });

  test('a default or builder name may be replaced; a typed name stays', () {
    expect(node('Smart Exposure', ['L']).hasAutoName, isTrue);
    expect(node('Smart Exposure: L+R', ['L', 'R']).hasAutoName, isTrue);
    expect(node('Smart Exposure: L+R', ['L', 'G']).hasAutoName, isFalse);
    expect(node('M31 broadband', ['L', 'R']).hasAutoName, isFalse);
  });
}
