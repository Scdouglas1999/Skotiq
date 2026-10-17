// The science settings rows must tell the truth about what is stored.
//
// The five text rows on this page were each a hand-rolled commit-on-blur field.
// Three of them rethrew a failed write into a future nobody held (so a refused
// save showed nothing at all and left the unsaved text on screen), the keyring
// row had no error path whatsoever, and none of them re-read the settings
// provider after mount, so a value written from another client or restored from
// a backup never reached the field.
//
// Rebuilding them on the canonical SettingsTextInput is what closes all of
// that; these tests assert the behaviour, not the widget.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/science_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Science settings that resolve immediately, record their writes, and accept
/// changes from outside the widget the way a remote push does.
class _FakeScienceSettings extends ScienceSettingsNotifier {
  _FakeScienceSettings({
    ScienceSettings initial = const ScienceSettings(),
    this.refuseWrites = false,
  }) : _value = initial;

  final bool refuseWrites;
  ScienceSettings _value;
  final writes = <String>[];

  @override
  Future<ScienceSettings> build() async => _value;

  void push(ScienceSettings next) {
    _value = next;
    state = AsyncData(next);
  }

  Future<void> _write(String label, ScienceSettings Function() apply) async {
    if (refuseWrites) throw StateError('settings write refused');
    writes.add(label);
    push(apply());
  }

  @override
  Future<void> setAavsoObserverCode(String code) =>
      _write(code, () => _value.copyWith(aavsoObserverCode: code));

  @override
  Future<void> setMpcObservatoryCode(String code) =>
      _write(code, () => _value.copyWith(mpcObservatoryCode: code));
}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = DisconnectedBackend();
  }
}

/// A keyring that is present but refuses to store, which is what a locked
/// keyring or an absent D-Bus secret service looks like from here.
class _LockedKeyring implements SecureKeyValueStore {
  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String value}) async {
    throw StateError('keyring is locked');
  }

  @override
  Future<void> delete({required String key}) async {}
}

Finder _fieldWithHint(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
      description: 'text field hinted "$hint"',
    );

String _textIn(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

Future<void> _pumpPage(
  WidgetTester tester, {
  required _FakeScienceSettings science,
  SecureKeyValueStore? keyring,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 2400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        scienceSettingsProvider.overrideWith(() => science),
        scienceRawSettingsProvider
            .overrideWith((ref) async => <String, String>{}),
        backendProvider.overrideWith(_StubBackendNotifier.new),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(keyring ?? InMemorySecureKeyValueStore()),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: ScienceSettingsPage()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Commit-on-blur: type, then move focus away.
Future<void> _typeAndBlur(
  WidgetTester tester,
  Finder field,
  String text,
) async {
  await tester.enterText(field, text);
  await tester.pump();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('a refused science write is reported, not swallowed',
      (tester) async {
    final science = _FakeScienceSettings(refuseWrites: true);
    await _pumpPage(tester, science: science);

    final field = _fieldWithHint('e.g. XYZ');
    expect(field, findsOneWidget);

    // Before the rebuild the rethrow landed on an unheld future: the operator
    // saw no error at all and the unsaved text stayed on screen.
    await _typeAndBlur(tester, field, 'ABC');

    expect(
      find.textContaining('Could not save aavso observer code'),
      findsWidgets,
      reason: 'a settings write the backend refused has to be visible',
    );
    expect(
      _textIn(tester, field),
      '',
      reason: 'the field must show what is stored, not what failed to store',
    );
    expect(science.writes, isEmpty);
  });

  testWidgets('a science value written elsewhere reaches the field',
      (tester) async {
    final science = _FakeScienceSettings(
      initial: const ScienceSettings(aavsoObserverCode: 'AAA'),
    );
    await _pumpPage(tester, science: science);

    final field = _fieldWithHint('e.g. XYZ');
    expect(_textIn(tester, field), 'AAA');

    // A remote push, a backup restore, or the other half of a master/slave
    // pair. Reading the provider once in initState leaves the field showing the
    // stale code.
    science.push(const ScienceSettings(aavsoObserverCode: 'BBB'));
    await tester.pump();

    expect(_textIn(tester, field), 'BBB');
  });

  testWidgets('an accepted code is normalised and stored', (tester) async {
    final science = _FakeScienceSettings();
    await _pumpPage(tester, science: science);

    await _typeAndBlur(tester, _fieldWithHint('e.g. XYZ'), ' xyz ');

    expect(science.writes, ['XYZ']);
    expect(_textIn(tester, _fieldWithHint('e.g. XYZ')), 'XYZ');
  });

  testWidgets('a malformed MPC code is refused and never written',
      (tester) async {
    final science = _FakeScienceSettings();
    await _pumpPage(tester, science: science);

    await _typeAndBlur(tester, _fieldWithHint('e.g. G40'), 'XY');

    expect(
      find.text('MPC codes must be exactly 3 letters or digits'),
      findsOneWidget,
    );
    expect(science.writes, isEmpty);
  });

  testWidgets('a keyring that refuses the TNS key does not claim it stored it',
      (tester) async {
    final science = _FakeScienceSettings();
    await _pumpPage(tester, science: science, keyring: _LockedKeyring());

    // The pre-rebuild row awaited the keyring write inside a try/finally with
    // no catch, from an unawaited caller: a locked keyring cleared nothing,
    // said nothing, and the operator believed the bot key was stored.
    await _typeAndBlur(tester, _fieldWithHint('paste key'), 'tns-secret');

    expect(
      find.textContaining('Could not store the TNS bot key'),
      findsWidgets,
    );
    expect(
      find.textContaining('Stored securely in the keyring'),
      findsNothing,
      reason: 'the subtitle must not report a key the keyring never took',
    );
  });
}
