import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/shortcuts.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/keys.dart';

MxTab panel(AppStore store, String id, String title) {
  final tab = MxTab(
    id: id,
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: TabKind.shell,
    cwd: '/repo',
    branch: '',
    customLabel: title,
  );
  store.tabs.add(tab);
  return tab;
}

const altG = MxChord(LogicalKeyboardKey.keyG, alt: true, meta: true);

/// As teclas que o mapa da janela atende. Um [SingleActivator] não se compara
/// com outro, então o que dá pra conferir é a tecla de cada um.
List<LogicalKeyboardKey> triggers(AppStore store) => MxKeys.bindings(
  store,
  _NoContext(),
).keys.whereType<SingleActivator>().map((a) => a.trigger).toList();

void main() {
  group('a tecla de um painel', () {
    test('nasce sem nenhuma: ninguém ganha ⌘1 por estar no topo', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store, 't1', 'primeiro');

      expect(tab.hotkey, isNull);
      expect(triggers(store), isNot(contains(LogicalKeyboardKey.digit1)));
    });

    test('⌘1…⌘9 voltaram a ser teclas que dá pra escolher', () {
      for (var d = 0; d < 9; d++) {
        final chord = MxChord(LogicalKeyboardKey(0x31 + d), meta: true);
        expect(chord.rejection, isNull, reason: chord.label);
      }
    });

    test('dada a um painel, sai do painel que a tinha', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final a = panel(store, 't1', 'primeiro');
      final b = panel(store, 't2', 'segundo');

      store.setHotkey(a, altG);
      store.setHotkey(b, altG);

      expect(a.hotkey, isNull);
      expect(b.hotkey, altG);
      expect(store.banner, contains('primeiro'));
    });

    test('null tira a tecla', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final a = panel(store, 't1', 'primeiro');

      store.setHotkey(a, altG);
      store.setHotkey(a, null);

      expect(a.hotkey, isNull);
    });

    test('uma ação que passa a usar a tecla a tira do painel', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final a = panel(store, 't1', 'primeiro');
      store.setHotkey(a, altG);

      store.bindShortcut(MxAction.openMarkdown, altG);

      expect(a.hotkey, isNull);
      expect(store.banner, contains('primeiro'));
    });

    test('vai pro layout, mas não pra receita de um grupo', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final a = panel(store, 't1', 'primeiro');
      store.setHotkey(a, altG);

      expect(a.toJson()['hotkey'], altG.id);
      expect(MxChord.parse(a.toJson()['hotkey'] as String), altG);
      expect(a.recipe.containsKey('hotkey'), isFalse);
    });

    test('vira um binding que leva ao painel', () {
      final store = AppStore();
      addTearDown(store.dispose);
      panel(store, 't1', 'primeiro');
      final b = panel(store, 't2', 'segundo');
      store.setHotkey(b, altG);

      expect(triggers(store), contains(LogicalKeyboardKey.keyG));
    });
  });
}

/// [MxKeys.bindings] só usa o contexto quando uma ação dispara; montar o mapa
/// não precisa de árvore nenhuma.
class _NoContext extends Fake implements BuildContext {}
