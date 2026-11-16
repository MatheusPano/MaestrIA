import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/shortcuts.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/keys.dart';
import 'package:maestria/ui/panes.dart';
import 'package:xterm/xterm.dart';

const _m4 = MxChord.mouse(kBackMouseButton);
const _m5 = MxChord.mouse(kForwardMouseButton);

/// A janela reduzida ao `_Keys` de `main.dart`: o mesmo [MxPointerKeys] em
/// volta de tudo, com [child] embaixo do ponteiro.
Future<void> pumpWindow(WidgetTester tester, AppStore store, {Widget? child}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Mx.theme(),
      home: Scaffold(
        body: Builder(
          builder: (ctx) =>
              MxPointerKeys(store: store, context: ctx, child: child ?? const SizedBox.expand()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Um clique de mouse com [button], do jeito que o embedder o entrega.
Future<void> click(WidgetTester tester, int button, {Offset at = const Offset(400, 300)}) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: button);
  await gesture.down(at);
  await gesture.up();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}

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

/// Desmonta antes de recolher o store: ver `closeWindow` em `shortcuts_test`.
Future<void> closeWindow(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  store.dispose();
}

void main() {
  group('a combinação de um botão', () {
    test('se escreve mouse4 no disco e volta igual', () {
      expect(_m4.id, 'mouse4');
      expect(_m5.id, 'mouse5');
      expect(MxChord.parse('mouse4'), _m4);
      const ctrlM5 = MxChord.mouse(kForwardMouseButton, control: true);
      expect(ctrlM5.id, 'ctrl+mouse5');
      expect(MxChord.parse('ctrl+mouse5'), ctrlM5);
    });

    test('não é a mesma coisa que tecla nenhuma', () {
      expect(_m4, isNot(MxChord.parse('4')));
      expect(_m4.activator, isNull);
    });

    test('um número que não é botão é descartado, não explode', () {
      for (final id in ['mouse', 'mouse0', 'mouse33', 'mouse04', 'mousex', 'hyper+mouse4']) {
        expect(MxChord.parse(id), isNull, reason: id);
      }
    });

    test('o esquerdo, o direito e o do meio são do terminal', () {
      for (final b in [kPrimaryMouseButton, kSecondaryMouseButton, kMiddleMouseButton]) {
        expect(MxChord.mouse(b).valid, isFalse);
        expect(MxChord.mouse(b, control: true).valid, isFalse);
      }
    });

    test('o de lado vale sem modificador: ele não escreve nada no terminal', () {
      expect(_m4.rejection, isNull);
      expect(_m5.rejection, isNull);
    });

    test('no Linux, do M6 em diante é recusado: o GTK não entrega', () {
      final was = MxChord.linux;
      addTearDown(() => MxChord.linux = was);
      const m6 = MxChord.mouse(kForwardMouseButton << 1);
      MxChord.linux = true;
      expect(m6.rejection, isNotNull);
      expect(_m5.rejection, isNull);
      MxChord.linux = false;
      expect(m6.rejection, isNull);
    });

    test('se lê como o número impresso no mouse', () {
      final was = MxChord.linux;
      addTearDown(() => MxChord.linux = was);
      MxChord.linux = true;
      expect(_m4.label, 'Mouse 4');
      expect(const MxChord.mouse(kBackMouseButton, control: true).label, 'Ctrl+Mouse 4');
    });
  });

  group('o mapa', () {
    test('grava o botão e o lê de volta', () {
      final keymap = MxKeymap()
        ..bind(MxAction.prevPane, _m4)
        ..bind(MxAction.nextPane, _m5);
      final json = keymap.toJson();
      expect(json[MxAction.prevPane.id], contains('mouse4'));

      final loaded = MxKeymap()..load(json);
      expect(loaded.owner(_m4), MxAction.prevPane);
      expect(loaded.owner(_m5), MxAction.nextPane);
      expect(loaded[MxAction.prevPane], MxAction.prevPane.defaults + [_m4]);
    });

    test('um config de antes, só com teclas, continua igual', () {
      final keymap = MxKeymap()
        ..load({
          MxAction.newClaude.id: ['meta+alt+t'],
        });
      expect(keymap[MxAction.newClaude], [
        const MxChord(LogicalKeyboardKey.keyT, meta: true, alt: true),
      ]);
      expect(keymap.isDefault(MxAction.nextPane), isTrue);
    });

    test('um clique esquerdo escrito à mão no arquivo é jogado fora', () {
      final keymap = MxKeymap()
        ..load({
          MxAction.prevPane.id: ['mouse1', 'mouse4'],
        });
      expect(keymap[MxAction.prevPane], [_m4]);
    });
  });

  group('na janela', () {
    testWidgets('o botão de lado dispara a ação', (tester) async {
      final store = AppStore();
      store.keymap.bind(MxAction.toggleSidebar, _m4);
      await pumpWindow(tester, store);

      await click(tester, kBackMouseButton);
      expect(store.sidebarHidden, isTrue);
      await click(tester, kBackMouseButton);
      expect(store.sidebarHidden, isFalse);

      await closeWindow(tester, store);
    });

    testWidgets('com o ponteiro em cima do terminal também', (tester) async {
      final store = AppStore();
      store.keymap.bind(MxAction.toggleSidebar, _m5);
      await pumpWindow(tester, store, child: TerminalView(Terminal(), autofocus: true));

      await click(tester, kForwardMouseButton);
      expect(store.sidebarHidden, isTrue);

      await closeWindow(tester, store);
    });

    testWidgets('o modificador tem que ser exatamente o do atalho', (tester) async {
      final store = AppStore();
      store.keymap.bind(MxAction.toggleSidebar, const MxChord.mouse(kBackMouseButton, control: true));
      await pumpWindow(tester, store);

      await click(tester, kBackMouseButton);
      expect(store.sidebarHidden, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await click(tester, kBackMouseButton);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(store.sidebarHidden, isTrue);

      await closeWindow(tester, store);
    });

    testWidgets('o clique esquerdo nem consulta o mapa', (tester) async {
      final store = AppStore();
      // Nem um config editado à mão faz o esquerdo virar atalho.
      store.keymap.bind(MxAction.toggleSidebar, const MxChord.mouse(kPrimaryMouseButton));
      await pumpWindow(tester, store);

      await click(tester, kPrimaryMouseButton);
      expect(store.sidebarHidden, isFalse);

      await closeWindow(tester, store);
    });

    // Cada painel puxa o foco no clique; se o botão de atalho fizesse o mesmo,
    // "fechar o painel em foco" fecharia o que está embaixo do ponteiro.
    testWidgets('age sobre o painel em foco, não o que está embaixo do ponteiro', (tester) async {
      final store = AppStore();
      final a = panel(store, 'a', 'primeiro');
      final b = panel(store, 'b', 'segundo');
      store.panes = PaneLeaf(a.id);
      store.focusedPaneId = a.id;
      store.dropTab(b, target: a, side: DropSide.right);
      store.focusPane(a);
      store.keymap.bind(MxAction.nextPane, _m5);
      await pumpWindow(
        tester,
        store,
        child: AnimatedBuilder(animation: store, builder: (_, _) => PaneArea(store: store)),
      );
      expect(store.focusedPaneId, a.id);

      final overB = tester.getCenter(find.byType(PaneArea)) + const Offset(200, 0);
      await click(tester, kForwardMouseButton, at: overB);
      expect(store.focusedPaneId, b.id, reason: 'de a pro próximo, que é b');
      await click(tester, kForwardMouseButton, at: overB);
      expect(store.focusedPaneId, a.id);

      await closeWindow(tester, store);
    });

    testWidgets('a tecla de um painel também pode ser um botão', (tester) async {
      final store = AppStore();
      panel(store, 't1', 'primeiro');
      final b = panel(store, 't2', 'segundo');
      store.panes = PaneLeaf('t1');
      store.focusedPaneId = 't1';
      store.setHotkey(b, _m5);
      await pumpWindow(tester, store);

      await click(tester, kForwardMouseButton);
      expect(store.focusedTab, b);

      await closeWindow(tester, store);
    });
  });


  test('um plugin que pede botão do mouse fica sem, com aviso', () {
    final m = PluginManifest.parse({
      'id': 'x',
      'version': '1',
      'contributes': {
        'commands': [
          {'id': 'c', 'title': 'c', 'run': 'ls', 'key': 'mouse4'},
        ],
      },
    });
    expect(m.commands.single.key, isNull);
    expect(m.warnings.single, contains('só usa teclado'));
  });
}
