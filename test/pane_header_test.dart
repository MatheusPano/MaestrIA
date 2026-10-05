import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/panel.dart';
import 'package:maestria/ui/terminal_pane.dart';

const closeTooltip = 'Tirar do painel — a sessão continua na lateral\n⌘⌫ encerra a sessão';

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

/// A decoração da faixa do cabeçalho -- o fundo dela é onde a cor do painel
/// aparece. Ver `paneHeaderBox`.
BoxDecoration header(WidgetTester tester) => tester
    .widgetList<Container>(
      find.descendant(of: find.byType(MxPanel), matching: find.byType(Container)),
    )
    .map((c) => c.decoration)
    .whereType<BoxDecoration>()
    .firstWhere((d) => d.border?.bottom.style == BorderStyle.solid && d.borderRadius == null);

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

  // O nome de um painel já estava no cabeçalho e a reclamação continuou vindo:
  // quem abre um painel por vez não *olha* pra um rótulo de 13px no topo, e o
  // scrollback de duas sessões do claude é igual. Daí a cor -- que não se lê,
  // se nota -- e o nome com peso de nome.
  group('a cor de um painel', () {
    testWidgets('sem escolha nenhuma, o cartão é o de sempre', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);
      await pumpPane(tester, store, tab);

      expect(store.tintOf(tab), isNull);
      expect(tester.widget<MxPanel>(find.byType(MxPanel)).tint, isNull);
      expect(header(tester).color, Mx.bgSidebar);
    });

    testWidgets('escolhida, ela pinta o cartão e a faixa', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      // No campo e não pelo [AppStore.setTabTint]: o save é debounced, e um
      // timer pendente derruba um teste de widget por invariante. Que a store
      // guarda a escolha é o que os dois testes abaixo cobrem.
      final tab = panel(store)..tint = MxTint.magenta;
      await pumpPane(tester, store, tab);

      expect(tester.widget<MxPanel>(find.byType(MxPanel)).tint, MxTint.magenta.color);
      expect(header(tester).color, isNot(Mx.bgSidebar));
    });

    test('e passa na frente da cor do grupo, que é automática', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);
      final group = PaneGroup(id: 'g1', name: 'GRID', panes: [tab.recipe]);
      store.groups.add(group);
      tab.groupId = group.id;

      expect(store.tintOf(tab), group.color);
      store.setTabTint(tab, MxTint.cyan);
      expect(store.tintOf(tab), MxTint.cyan.color);
    });

    // A sugestão que veio depois: pintar o *trabalho*, não uma sessão de cada
    // vez. Quatro painéis de uma task nascem da mesma cor sem ninguém pintar
    // painel nenhum.
    test('o painel de um projeto pintado já nasce com a cor dele', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);
      final featureOrHotfix = store.addFeatureOrHotfix(tab.folder, 'permissão do google');
      tab.featureOrHotfixId = featureOrHotfix.id;

      expect(store.tintOf(tab), isNull);
      store.setFeatureOrHotfixTint(featureOrHotfix, MxTint.cyan);
      // Herdada e não copiada: o painel continua sem cor própria.
      expect(tab.tint, isNull);
      expect(store.tintOf(tab), MxTint.cyan.color);
      // E repintar o projeto repinta o painel, que é o ponto de herdar.
      store.setFeatureOrHotfixTint(featureOrHotfix, MxTint.red);
      expect(store.tintOf(tab), MxTint.red.color);
    });

    // Projeto pintado manda no painel: a cor dele diz "estas quatro sessões
    // são o mesmo trabalho", e uma delas destoando desfaz a frase.
    test('e a do projeto manda na do painel, sem apagá-la', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);
      final featureOrHotfix = store.addFeatureOrHotfix(tab.folder, 'permissão do google');
      tab.featureOrHotfixId = featureOrHotfix.id;
      store.setTabTint(tab, MxTint.red);
      expect(store.tintOf(tab), MxTint.red.color);

      store.setFeatureOrHotfixTint(featureOrHotfix, MxTint.cyan);
      expect(store.tintOf(tab), MxTint.cyan.color);
      // Guardada por baixo, não perdida: o projeto ficando sem cor devolve a
      // do painel, em vez de deixá-lo sem cor nenhuma.
      expect(tab.tint, MxTint.red);
      store.setFeatureOrHotfixTint(featureOrHotfix, null);
      expect(store.tintOf(tab), MxTint.red.color);
    });

    test('e sair do projeto devolve o painel pra cor dele', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store)..tint = MxTint.yellow;
      final featureOrHotfix = store.addFeatureOrHotfix(tab.folder, 'permissão do google');
      tab.featureOrHotfixId = featureOrHotfix.id;
      store.setFeatureOrHotfixTint(featureOrHotfix, MxTint.cyan);
      expect(store.tintOf(tab), MxTint.cyan.color);

      tab.featureOrHotfixId = null;
      expect(store.tintOf(tab), MxTint.yellow.color);
    });

    // A pasta é o terceiro andar, e o único que não manda: ela pinta quem
    // ninguém pintou. Um repo guarda vários trabalhos, e uma cor que mandasse
    // ali apagaria a distinção entre eles.
    test('a da pasta é o fundo: vale pro painel que ninguém pintou', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);
      store.folders.add(tab.folder);

      store.setFolderTint(tab.folder, MxTint.yellow);
      expect(store.tintOf(tab), MxTint.yellow.color);

      // O painel escolhe outra e ela vale, ao contrário do que acontece com a
      // do projeto.
      store.setTabTint(tab, MxTint.red);
      expect(store.tintOf(tab), MxTint.red.color);

      // E o projeto, se houver, manda nos dois.
      final featureOrHotfix = store.addFeatureOrHotfix(tab.folder, 'permissão do google');
      tab.featureOrHotfixId = featureOrHotfix.id;
      store.setFeatureOrHotfixTint(featureOrHotfix, MxTint.cyan);
      expect(store.tintOf(tab), MxTint.cyan.color);
    });

    test('e a da pasta atravessa o fechamento da janela', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final folder = panel(store).folder;
      expect(folder.toJson()['tint'], isNull);

      store.setFolderTint(folder, MxTint.green);
      expect(folder.toJson()['tint'], 'green');
      expect(Folder.fromJson(folder.toJson()).tint, MxTint.green);
    });

    test('a do projeto também atravessa o fechamento da janela', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final featureOrHotfix = store.addFeatureOrHotfix(panel(store).folder, 'permissão do google');
      expect(featureOrHotfix.toJson()['tint'], isNull);

      store.setFeatureOrHotfixTint(featureOrHotfix, MxTint.magenta);
      expect(featureOrHotfix.toJson()['tint'], 'magenta');
      expect(FeatureOrHotfix.fromJson(featureOrHotfix.toJson()).tint, MxTint.magenta);
    });

    test('atravessa o fechamento da janela, pelo papel e não pelo valor', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);
      expect(tab.recipe['tint'], isNull);

      store.setTabTint(tab, MxTint.green);
      // O nome do papel, pra que a cor siga a paleta em vigor amanhã.
      expect(tab.recipe['tint'], 'green');

      store.setTabTint(tab, null);
      expect(tab.recipe['tint'], isNull);
    });
  });

  group('o nome no cabeçalho', () {
    // O que a reclamação pedia: ele é a identidade do painel, não mais uma
    // ficha da faixa.
    testWidgets('não apaga junto com o resto num painel fora de foco', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store, title: 'permissão do google');
      final other = MxTab(
        id: 'tab2',
        folder: tab.folder,
        kind: TabKind.claude,
        cwd: '/repo',
        branch: '',
        customLabel: 'o outro',
      );
      store.tabs.add(other);
      // Dois painéis, e o teclado no outro: é aqui que o cabeçalho apagava.
      store.panes = PaneSplit(PaneAxis.row, [PaneLeaf(tab.id), PaneLeaf(other.id)], [0.5, 0.5]);
      store.focusedPaneId = other.id;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 720,
              height: 320,
              child: TerminalPane(store: store, tab: tab, focused: false, showFocus: true),
            ),
          ),
        ),
      );

      expect(
        find.ancestor(of: find.text('permissão do google'), matching: find.byType(Opacity)),
        findsNothing,
      );
      // E o resto da faixa apaga, que é o que faz o nome se destacar nela.
      expect(
        find.ancestor(of: find.byTooltip(closeTooltip), matching: find.byType(Opacity)),
        findsOne,
      );
    });

    testWidgets('e leva a tecla que abre este painel, como a linha da lateral', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);
      await pumpPane(tester, store, tab);

      expect(find.descendant(of: find.byType(PaneKeyHint), matching: find.text('⌘1')), findsOne);
    });
  });
}
