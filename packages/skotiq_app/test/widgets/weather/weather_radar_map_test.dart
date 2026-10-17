import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/weather/weather_radar_map.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('RainViewer tiles stop at the provider native zoom limit',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final frame = RadarFrame(
      timestamp: DateTime.utc(2026, 8, 18, 15),
      tileUrlTemplate:
          'https://tilecache.rainviewer.com/v2/radar/123/256/{z}/{x}/{y}/2/1_1.png',
      north: 41,
      south: 39,
      east: -74,
      west: -76,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: WeatherRadarMap(
              currentFrame: frame,
              latitude: 40,
              longitude: -75,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final layers =
        tester.widgetList<TileLayer>(find.byType(TileLayer)).toList();
    final radarLayer = layers.singleWhere(
      (layer) => layer.urlTemplate == frame.tileUrlTemplate,
    );

    expect(radarLayer.maxNativeZoom, 7);
    expect(tester.takeException(), isNull);
  });
}
