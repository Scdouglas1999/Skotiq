// The night APIs' answers for calendar dates, pinned so a change to how a
// night is named cannot move any caller's result. Every value is an instant,
// and the night of a date opens at the site's mean solar noon whatever zone
// the computer is in, so the pins hold in every time zone.
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

typedef _Pin = ({
  double lat,
  double lon,
  String date,
  String nightStart,
  String nightMiddle,
  String nightDateOf,
  String? dusk,
  String? dawn,
  String? rise,
  String? transit,
  String? set,
});

const List<_Pin> _pins = [
  (
    lat: 39.9846,
    lon: -75.3514,
    date: '2026-07-25T00:00:00.000Z',
    nightStart: '2026-07-25T17:01:00.000Z',
    nightMiddle: '2026-07-26T05:01:00.000Z',
    nightDateOf: '2026-7-24',
    dusk: '2026-07-26T02:13:30.000Z',
    dawn: '2026-07-26T08:02:49.570Z',
    rise: '2026-07-26T08:35:32.460Z',
    transit: '2026-07-26T14:19:26.315Z',
    set: '2026-07-26T20:03:19.452Z',
  ),
  (
    lat: 39.9846,
    lon: -75.3514,
    date: '2026-07-26T01:30:00.000Z',
    nightStart: '2026-07-26T17:01:00.000Z',
    nightMiddle: '2026-07-27T05:01:00.000Z',
    nightDateOf: '2026-7-25',
    dusk: '2026-07-27T02:12:05.625Z',
    dawn: '2026-07-27T08:04:13.945Z',
    rise: '2026-07-27T08:31:36.914Z',
    transit: '2026-07-27T14:15:30.006Z',
    set: '2026-07-27T19:59:23.906Z',
  ),
  (
    lat: 39.9846,
    lon: -75.3514,
    date: '2026-12-21T23:59:00.000Z',
    nightStart: '2026-12-21T17:01:00.000Z',
    nightMiddle: '2026-12-22T05:01:00.000Z',
    nightDateOf: '2026-12-21',
    dusk: '2026-12-21T23:17:10.312Z',
    dawn: '2026-12-22T10:42:31.406Z',
    rise: '2026-12-21T22:49:42.070Z',
    transit: '2026-12-22T04:33:35.865Z',
    set: '2026-12-22T10:17:28.476Z',
  ),
  (
    lat: 39.9846,
    lon: -75.3514,
    date: '2027-03-14T12:00:00.000Z',
    nightStart: '2027-03-14T17:01:00.000Z',
    nightMiddle: '2027-03-15T05:01:00.000Z',
    nightDateOf: '2027-3-13',
    dusk: '2027-03-15T00:37:22.031Z',
    dawn: '2027-03-15T09:43:03.046Z',
    rise: '2027-03-14T17:23:22.382Z',
    transit: '2027-03-14T23:07:15.322Z',
    set: '2027-03-15T04:51:08.789Z',
  ),
  (
    lat: 35.68,
    lon: 139.69,
    date: '2026-07-25T00:00:00.000Z',
    nightStart: '2026-07-25T02:41:00.000Z',
    nightMiddle: '2026-07-25T14:41:00.000Z',
    nightDateOf: '2026-7-24',
    dusk: '2026-07-25T11:32:47.812Z',
    dawn: '2026-07-25T18:03:08.906Z',
    rise: '2026-07-25T18:15:17.226Z',
    transit: '2026-07-26T00:01:37.358Z',
    set: '2026-07-26T05:47:57.186Z',
  ),
  (
    lat: 35.68,
    lon: 139.69,
    date: '2026-07-26T01:30:00.000Z',
    nightStart: '2026-07-26T02:41:00.000Z',
    nightMiddle: '2026-07-26T14:41:00.000Z',
    nightDateOf: '2026-7-25',
    dusk: '2026-07-26T11:31:41.601Z',
    dawn: '2026-07-26T18:04:15.703Z',
    rise: '2026-07-26T18:11:21.679Z',
    transit: '2026-07-26T23:57:41.465Z',
    set: '2026-07-27T05:44:00.468Z',
  ),
  (
    lat: 35.68,
    lon: 139.69,
    date: '2026-12-21T23:59:00.000Z',
    nightStart: '2026-12-21T02:41:00.000Z',
    nightMiddle: '2026-12-21T14:41:00.000Z',
    nightDateOf: '2026-12-21',
    dusk: '2026-12-21T09:03:00.117Z',
    dawn: '2026-12-21T20:15:45.937Z',
    rise: '2026-12-21T08:29:26.835Z',
    transit: '2026-12-21T14:15:46.419Z',
    set: '2026-12-21T20:02:06.210Z',
  ),
  (
    lat: 35.68,
    lon: 139.69,
    date: '2027-03-14T12:00:00.000Z',
    nightStart: '2027-03-14T02:41:00.000Z',
    nightMiddle: '2027-03-14T14:41:00.000Z',
    nightDateOf: '2027-3-14',
    dusk: '2027-03-14T10:12:13.242Z',
    dawn: '2027-03-14T19:28:15.937Z',
    rise: '2027-03-14T03:03:05.976Z',
    transit: '2027-03-14T08:49:26.315Z',
    set: '2027-03-14T14:35:45.351Z',
  ),
  (
    lat: 51.48,
    lon: 0.0,
    date: '2026-07-25T00:00:00.000Z',
    nightStart: '2026-07-25T12:00:00.000Z',
    nightMiddle: '2026-07-26T00:00:00.000Z',
    nightDateOf: '2026-7-24',
    dusk: '2026-07-25T23:10:56.250Z',
    dawn: '2026-07-26T01:02:41.718Z',
    rise: '2026-07-26T03:43:19.804Z',
    transit: '2026-07-26T09:18:51.083Z',
    set: '2026-07-26T14:54:22.499Z',
  ),
  (
    lat: 51.48,
    lon: 0.0,
    date: '2026-07-26T01:30:00.000Z',
    nightStart: '2026-07-26T12:00:00.000Z',
    nightMiddle: '2026-07-27T00:00:00.000Z',
    nightDateOf: '2026-7-25',
    dusk: '2026-07-26T23:05:18.750Z',
    dawn: '2026-07-27T01:08:19.218Z',
    rise: '2026-07-27T03:39:24.257Z',
    transit: '2026-07-27T09:14:55.204Z',
    set: '2026-07-27T14:50:26.952Z',
  ),
  (
    lat: 51.48,
    lon: 0.0,
    date: '2026-12-21T23:59:00.000Z',
    nightStart: '2026-12-21T12:00:00.000Z',
    nightMiddle: '2026-12-22T00:00:00.000Z',
    nightDateOf: '2026-12-21',
    dusk: '2026-12-21T17:57:20.625Z',
    dawn: '2026-12-22T05:59:19.570Z',
    rise: '2026-12-21T17:57:29.414Z',
    transit: '2026-12-21T23:33:00.660Z',
    set: '2026-12-22T05:08:32.695Z',
  ),
  (
    lat: 51.48,
    lon: 0.0,
    date: '2027-03-14T12:00:00.000Z',
    nightStart: '2027-03-14T12:00:00.000Z',
    nightMiddle: '2027-03-15T00:00:00.000Z',
    nightDateOf: '2027-3-14',
    dusk: '2027-03-14T19:54:43.593Z',
    dawn: '2027-03-15T04:22:45.820Z',
    rise: '2027-03-14T12:31:08.554Z',
    transit: '2027-03-14T18:06:40.309Z',
    set: '2027-03-14T23:42:11.835Z',
  ),
];

String? _iso(DateTime? t) => t?.toUtc().toIso8601String();

void main() {
  for (final pin in _pins) {
    final date = DateTime.parse(pin.date);
    group('${pin.lat}, ${pin.lon} on ${pin.date}', () {
      test('night start and middle', () {
        expect(
          _iso(
            AstronomyCalculations.nightStartOf(
              NightDate.ofCalendarDay(date),
              longitudeDeg: pin.lon,
            ),
          ),
          pin.nightStart,
        );
        expect(
          _iso(
            AstronomyCalculations.nightMiddleOf(
              NightDate.ofCalendarDay(date),
              longitudeDeg: pin.lon,
            ),
          ),
          pin.nightMiddle,
        );
      });

      test('the night an instant belongs to', () {
        final night = AstronomyCalculations.nightDateOf(
          date,
          longitudeDeg: pin.lon,
        );
        expect('${night.year}-${night.month}-${night.day}', pin.nightDateOf);
      });

      test('twilight', () {
        final twilight = AstronomyCalculations.calculateTwilightTimes(
          date: NightDate.ofCalendarDay(date),
          latitudeDeg: pin.lat,
          longitudeDeg: pin.lon,
        );
        expect(_iso(twilight.astronomicalDusk), pin.dusk);
        expect(_iso(twilight.astronomicalDawn), pin.dawn);
      });

      test('rise, transit and set of M42', () {
        final visibility = AstronomyCalculations.calculateObjectVisibility(
          raDeg: 83.8,
          decDeg: -5.4,
          date: NightDate.ofCalendarDay(date),
          latitudeDeg: pin.lat,
          longitudeDeg: pin.lon,
        );
        expect(_iso(visibility.riseTime), pin.rise);
        expect(_iso(visibility.transitTime), pin.transit);
        expect(_iso(visibility.setTime), pin.set);
      });
    });
  }
}
