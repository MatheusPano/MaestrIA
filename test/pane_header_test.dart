import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/terminal_pane.dart';

const closeTooltip = 'tirar do painel — a sessão continua na lateral\n⌘⌫ encerra a sessão';

MxTab panel(AppStore store, {String title = 'maestria_v2'}) {
  final tab = MxTab(
    id: 'tab1',
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: title,
  );
  store.tabs.add(tab);
  store.panes = PaneLeaf(tab.id);
  store.focusedPaneId = tab.id;
  return tab;
}

Future<void> pumpPane(WidgetTester tester, AppStore store, MxTab tab) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 720,
        height: 320,
        child: TerminalPane(store: store, tab: tab),
      ),
    ),
  ),
);

Future<Rect> closeButton(WidgetTester tester, {required String title}) async {
  final store = AppStore();
  await pumpPane(tester, store, panel(store, title: title));
  return tester.getRect(find.byTooltip(closeTooltip));
}

void main() {
  group('pane header', () {
    testWidgets('the close button sits on the right edge', (tester) async {
      final close = await closeButton(tester, title: 'maestria_v2');
      final pane = tester.getRect(find.byType(TerminalPane));
      // Header padding plus the panel's own border, and nothing else. It used
      // to be ~120px in from here: the title's unclaimed flex share.
      expect(pane.right - close.right, lessThan(12));
    });

    testWidgets('and stays there however long the title is', (tester) async {
      final short = await closeButton(tester, title: 'a');
      final long = await closeButton(tester, title: 'TASK#47730 refatorar a autenticação');
      expect(short, long);
    });
  });

  group('o X do header', () {
    testWidgets('tira o painel da tela e deixa a sessão viva', (tester) async {
      final store = AppStore();
      final tab = panel(store);
      await pumpPane(tester, store, tab);

      await tester.tap(find.byTooltip(closeTooltip));
      await tester.pump();

      // A tela limpa; a conversa não. Encerrar é o X da lateral, o menu e ⌘⌫.
      expect(store.panes, isNull);
      expect(store.tabs, contains(tab));
      expect(tab.term.exited, isFalse);
      store.dispose();
    });

    test('com dois painéis abertos, sobra o outro — e o corte some com ele', () {
      final store = AppStore();
      final left = panel(store);
      final right = MxTab(
        id: 'tab2',
        folder: left.folder,
        kind: TabKind.claude,
        cwd: '/repo',
        branch: '',
        customLabel: 'o outro',
      );
      store.tabs.add(right);
      store.panes = PaneSplit(PaneAxis.row, [PaneLeaf(left.id), PaneLeaf(right.id)], [0.5, 0.5]);
      store.focusedPaneId = right.id;

      store.dismiss(left);

      expect(Panes.order(store.panes), [right.id]);
      expect(store.panes, isA<PaneLeaf>());
      expect(store.focusedPaneId, right.id);
      expect(store.tabs, containsAll([left, right]));
      store.dispose();
    });
  });

  group('a digital', () {
    late List<MethodCall> clipboard;

    setUp(() {
      clipboard = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboard.add(call);
          return null;
        },
      );
    });

    testWidgets('copia o nome pelo qual outro agente fala com a sessão', (tester) async {
      final store = AppStore();
      final tab = panel(store)
        ..agentName = 'esconder subagents'
        ..sessionId = 'd415f507-208c-4d05-894a-88d9f72fa8fd';
      await pumpPane(tester, store, tab);

      await tester.tap(find.byIcon(Icons.fingerprint));
      await tester.pump();

      expect(clipboard.single.arguments['text'], 'esconder subagents');
      store.dispose();
    });

    testWidgets('e o id da sessão no ⌥ clique', (tester) async {
      final store = AppStore();
      final tab = panel(store)
        ..agentName = 'esconder subagents'
        ..sessionId = 'd415f507-208c-4d05-894a-88d9f72fa8fd';
      await pumpPane(tester, store, tab);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tap(find.byIcon(Icons.fingerprint));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      expect(clipboard.single.arguments['text'], 'd415f507-208c-4d05-894a-88d9f72fa8fd');
      store.dispose();
    });

    testWidgets('avisa quando o nome não endereça uma sessão só', (tester) async {
      final store = AppStore();
      final tab = panel(store)..agentName = 'maestria_v2';
      store.tabs.add(
        MxTab(id: 'tab2', folder: tab.folder, kind: TabKind.claude, cwd: '/repo', branch: '')
          ..agentName = 'maestria_v2',
      );
      await pumpPane(tester, store, tab);

      await tester.tap(find.byIcon(Icons.fingerprint));
      await tester.pump();

      expect(store.banner, contains('cuidado'));
      store.dispose();
    });
  });
}
