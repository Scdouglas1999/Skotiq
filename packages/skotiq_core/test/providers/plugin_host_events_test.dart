// The app's weather and focuser readings reach the plugins that listen for
// them ("weather.updated", "focuser.moved"), the events the Weather Logger and
// the sequence-delay plugin subscribe to.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

class _Listener extends SkotiqPlugin {
  final events = <(String, Map<String, dynamic>)>[];

  @override
  String get id => 'com.test.listener';
  @override
  String get name => 'Listener';
  @override
  String get version => '1.0.0';
  @override
  String get description => 'Records app events';
  @override
  String get author => 'test';

  @override
  Future<void> onLoad(PluginContext context) async {
    for (final name in ['weather.updated', 'focuser.moved']) {
      context.eventBus.on(name).listen((data) => events.add((name, data)));
    }
  }

  @override
  Future<void> onUnload() async {}
}

class _Weather extends WeatherStateNotifier {
  _Weather(super.ref);
  void set(WeatherState next) => state = next;
}

class _Focuser extends FocuserStateNotifier {
  _Focuser(super.ref);
  void set(FocuserState next) => state = next;
}

void main() {
  test('weather readings and focuser moves are published to plugins', () async {
    final host = PluginHost(
      contextFactory: PluginContextFactory(
        storageFactory: (_) => InMemoryPluginStorage(),
      ),
    );
    addTearDown(host.dispose);
    final listener = _Listener();
    await host.registerPlugin(listener);

    late _Weather weather;
    late _Focuser focuser;
    final container = ProviderContainer(
      overrides: [
        pluginHostProvider.overrideWithValue(host),
        weatherStateProvider.overrideWith((ref) => weather = _Weather(ref)),
        focuserStateProvider.overrideWith((ref) => focuser = _Focuser(ref)),
      ],
    );
    addTearDown(container.dispose);
    container.read(pluginHostEventsProvider);
    container.read(weatherStateProvider);
    container.read(focuserStateProvider);

    final sampled = DateTime.utc(2026, 11, 22, 3);
    weather.set(
      WeatherState(
        connectionState: DeviceConnectionState.connected,
        temperature: 4.5,
        humidity: 80,
        lastUpdated: sampled,
      ),
    );
    // The same reading again is not a new one.
    weather.set(
      WeatherState(
        connectionState: DeviceConnectionState.connected,
        temperature: 4.5,
        humidity: 80,
        lastUpdated: sampled,
        deviceName: 'Station',
      ),
    );
    focuser.set(
      const FocuserState(
        connectionState: DeviceConnectionState.connected,
        position: 25300,
        temperature: 3.0,
      ),
    );
    focuser.set(
      const FocuserState(
        connectionState: DeviceConnectionState.connected,
        position: 25300,
        temperature: 2.9,
      ),
    );
    await pumpEventQueue();

    expect(listener.events.map((e) => e.$1), [
      'weather.updated',
      'focuser.moved',
    ]);
    expect(listener.events.first.$2['temperature'], 4.5);
    expect(listener.events.first.$2['humidity'], 80);
    expect(listener.events.last.$2, {'position': 25300, 'temperature': 3.0});
  });
}
