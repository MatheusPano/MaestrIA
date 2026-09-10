import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';

AppStore storeWithFolder() {
  final store = AppStore();
  store.folders.add(
    Folder(root: '/repo', name: 'meu-repo')
      ..isRepo = true
      ..branch = 'master',
  );
  return store;
}

MxTab panel(AppStore store, String name, {Folder? folder}) {
  final where = folder ?? store.folders.first;
  final tab = MxTab(
    id: name,
    folder: where,
    kind: TabKind.claude,
    cwd: where.root,
    branch: '',
    customLabel: name,
  );
  store.tabs.add(tab);
  return tab;
}

/// Wide enough for the header rows to fit — see worktrees_test.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 660, height: 900, child: Sidebar(store: store)),
    ),
  ),
);

/// Parks a mouse on a row and leaves it there: the + only exists while the
/// pointer is on the header it rides on.
Future<void> hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(target));
  // Not pumpAndSettle: a claude row's mark animates forever, so a settle with
  // one of them on screen never comes.
  await tester.pump(const Duration(milliseconds: 200));
}

double opacityOf(WidgetTester tester, String tooltip) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(AnimatedOpacity)),
    )
    .opacity;

void main() {
  group('the loose tray', () {
    testWidgets('is a divider, not a folder', (tester) async {
      final store = storeWithFolder();
      panel(store, 'solto', folder: store.loose);
      await pumpSidebar(tester, store);

      expect(find.text('avulsos'), findsOneWidget);
      // Nothing to fold: the one open chevron on screen is the real folder's.
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      // And nothing that says "directory": no glyph, no explaining subtitle.
      expect(find.byIcon(Icons.scatter_plot_outlined), findsNothing);
      expect(find.text('fora de qualquer pasta'), findsNothing);
      expect(find.byType(RepoGlyph), findsOneWidget);
    });

    testWidgets('hangs its panels at the top level, not stepped in', (tester) async {
      final store = storeWithFolder();
      panel(store, 'na pasta');
      panel(store, 'solto', folder: store.loose);
      await pumpSidebar(tester, store);

      // A folder's panels are inside it and carry the step to prove it. The
      // tray's are inside nothing, so they start further left.
      final nested = tester.getTopLeft(find.text('na pasta')).dx;
      final loose = tester.getTopLeft(find.text('solto')).dx;
      expect(loose, lessThan(nested));
    });

    testWidgets('counts what is in it, and keeps quiet when empty', (tester) async {
      final store = storeWithFolder();
      await pumpSidebar(tester, store);
      // The folder's own zero is the only count on screen.
      expect(find.text('0'), findsOneWidget);

      panel(store, 'solto', folder: store.loose);
      panel(store, 'outro', folder: store.loose);
      await pumpSidebar(tester, store);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('offers what you can start here behind one +', (tester) async {
      final store = storeWithFolder();
      await pumpSidebar(tester, store);

      // No chips under the rows any more: one + on the tray's own line.
      expect(find.text('terminal'), findsNothing);
      await tester.tap(find.byTooltip('abrir algo sem pasta'));
      await tester.pumpAndSettle();

      expect(find.text('sessão do claude'), findsOneWidget);
      expect(find.text('terminal'), findsOneWidget);
      // Projeto inclusive: nomear um trabalho não pede repo nenhum.
      expect(find.text('projeto…'), findsOneWidget);
    });

    testWidgets("and a folder's + offers the same project line", (tester) async {
      final store = storeWithFolder();
      await pumpSidebar(tester, store);

      await tester.tap(find.byTooltip('abrir algo nessa pasta'));
      await tester.pumpAndSettle();
      expect(find.text('projeto…'), findsOneWidget);
    });

    testWidgets('the + waits for the pointer once there is a row to hover', (tester) async {
      final store = storeWithFolder();
      panel(store, 'na pasta');
      panel(store, 'solto', folder: store.loose);
      await pumpSidebar(tester, store);

      // Something in both groups, so neither + is the only thing to aim at.
      expect(opacityOf(tester, 'abrir algo nessa pasta'), 0);
      expect(opacityOf(tester, 'abrir algo sem pasta'), 0);

      await hover(tester, find.text('meu-repo'));
      expect(opacityOf(tester, 'abrir algo nessa pasta'), 1);
      // One row at a time: the tray's stays down.
      expect(opacityOf(tester, 'abrir algo sem pasta'), 0);
    });

    // A varrida que se faz toda hora aqui: a bandeja é onde as sessões de uma
    // tarde se acumulam, e ela estava a dois cliques dentro do ⋯.
    testWidgets('limpa o concluído e deixa o resto', (tester) async {
      final store = storeWithFolder();
      panel(store, 'ainda roda', folder: store.loose);
      final feito = panel(store, 'essa funcionou', folder: store.loose);
      await pumpSidebar(tester, store);

      // Nada acabado ainda: um limpar que não tem o que limpar não existe.
      expect(find.byTooltip('limpar 1 painel concluído'), findsNothing);

      store.setDone(feito, true);
      await pumpSidebar(tester, store);
      await hover(tester, find.text('avulsos'));
      expect(opacityOf(tester, 'limpar 1 painel concluído'), 1);

      await tester.tap(find.byTooltip('limpar 1 painel concluído'));
      await tester.pump();

      expect(store.tabsOf(store.loose).map((t) => t.title), ['ainda roda']);
      // Uma linha que sai da lateral é fácil de não ver: o botão se explica.
      expect(store.banner, contains('um painel fechado'));
      store.dispose();
    });

    // A outra porta da mesma varrida, e a que existia antes do botão: o ⋯.
    testWidgets('a varrida do ⋯ diz o que levou, e deixa o encerrado', (tester) async {
      final store = storeWithFolder();
      panel(store, 'ainda roda', folder: store.loose);
      final feito = panel(store, 'essa funcionou', folder: store.loose);
      final morto = panel(store, 'saiu na largada', folder: store.loose);
      store.setDone(feito, true);
      morto.term.exited = true;
      await pumpSidebar(tester, store);

      await tester.tap(find.byTooltip('o que fazer com os avulsos'));
      // Nunca pumpAndSettle: a marca de uma sessão do claude pulsa pra sempre,
      // e uma delas está na bandeja. Um frame põe o menu de pé e o outro
      // termina a abertura dele -- antes disso a rota engole o clique.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('limpar concluídos'));
      await tester.pump();

      // O encerrado *não* vai junto: um processo que saiu é um painel
      // esperando pra rodar de novo, não um trabalho acabado. Ver
      // [AppStore.closeSettled].
      expect(store.tabsOf(store.loose).map((t) => t.title), [
        'ainda roda',
        'saiu na largada',
      ]);
      expect(store.banner, contains('um painel fechado'));
      store.dispose();
    });

    // O ⋯ oferece a varrida sempre, ao contrário do botão da régua: então aqui
    // ela pode não ter o que levar, e um clique que não faz nada e não diz
    // nada é um clique que se dá de novo.
    testWidgets('e diz também quando não havia nada pra levar', (tester) async {
      final store = storeWithFolder();
      panel(store, 'ainda roda', folder: store.loose);
      await pumpSidebar(tester, store);

      await tester.tap(find.byTooltip('o que fazer com os avulsos'));
      // Nunca pumpAndSettle: a marca de uma sessão do claude pulsa pra sempre,
      // e uma delas está na bandeja. Um frame põe o menu de pé e o outro
      // termina a abertura dele -- antes disso a rota engole o clique.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('limpar concluídos'));
      await tester.pump();

      expect(store.tabsOf(store.loose), hasLength(1));
      expect(store.banner, contains('nada pra limpar aqui'));
      store.dispose();
    });

    // Varrer durante uma busca fecharia painéis que a busca está escondendo.
    testWidgets('o limpar sai de cena enquanto se procura', (tester) async {
      final store = storeWithFolder();
      panel(store, 'ainda roda', folder: store.loose);
      final feito = panel(store, 'essa funcionou', folder: store.loose);
      store.setDone(feito, true);
      await pumpSidebar(tester, store);
      expect(find.byTooltip('limpar 1 painel concluído'), findsOneWidget);

      store.setQuery('roda');
      await pumpSidebar(tester, store);
      expect(find.byTooltip('limpar 1 painel concluído'), findsNothing);
      store.dispose();
    });
  });
}
