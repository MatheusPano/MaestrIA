import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';
import 'package:maestria/ui/terminal_pane.dart';

AppStore storeWith(List<String> names) {
  final store = AppStore();
  for (final n in names) {
    store.folders.add(Folder(root: '/repos/$n', name: n)..isRepo = true);
  }
  return store;
}

Folder named(AppStore s, String name) => s.folders.firstWhere((f) => f.name == name);

MxTab shell(AppStore s, Folder f, String id, String label) {
  final tab = MxTab(id: id, folder: f, kind: TabKind.shell, cwd: f.root, branch: '', customLabel: label);
  s.tabs.add(tab);
  return tab;
}

Future<void> pumpSidebar(WidgetTester tester, AppStore store, {double height = 900}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 660,
        height: height,
        child: AnimatedBuilder(animation: store, builder: (_, _) => Sidebar(store: store)),
      ),
    ),
  ),
);

void main() {
  // O store descartado no fim do corpo, não num addTearDown: ver
  // sidebar_workspaces_test.dart.
  group('revealTab no store', () {
    test('abre o workspace, a pasta daquela aparição e a feature', () {
      final store = storeWith(['infra']);
      final infra = named(store, 'infra');
      final ws = store.createWorkspace('ATRIUM', folders: [infra]);
      final feature = store.addFeatureOrHotfix(infra, 'login');
      final tab = shell(store, infra, 't1', 'servidor')..featureOrHotfixId = feature.id;
      ws.collapsed = true;
      ws.collapsedFolders.add(infra.root);
      feature.collapsed = true;

      store.revealTab(tab);

      expect(ws.collapsed, isFalse);
      expect(ws.collapsedFolders, isNot(contains(infra.root)));
      expect(feature.collapsed, isFalse);
      expect(store.revealedTabId, 't1');
      expect(store.revealedWithin, ws);
      store.dispose();
    });

    test('pasta espelhada: revela a aparição do primeiro workspace da lateral', () {
      final store = storeWith(['infra']);
      final infra = named(store, 'infra');
      final atrium = store.createWorkspace('ATRIUM', folders: [infra]);
      final uplii = store.createWorkspace('UPLII', folders: [infra]);
      store.moveRootRow(uplii, atrium);
      expect(store.sidebarRows.whereType<Workspace>().first, uplii);
      final tab = shell(store, infra, 't1', 'servidor');
      atrium.collapsedFolders.add(infra.root);
      uplii.collapsedFolders.add(infra.root);

      store.revealTab(tab);

      expect(store.revealedWithin, uplii);
      expect(uplii.collapsedFolders, isEmpty);
      expect(atrium.collapsedFolders, contains(infra.root));
      store.dispose();
    });

    test('pasta solta: aparição na raiz', () {
      final store = storeWith(['solta']);
      final solta = named(store, 'solta');
      solta.collapsed = true;
      final tab = shell(store, solta, 't1', 'servidor');

      store.revealTab(tab);

      expect(store.revealedWithin, isNull);
      expect(store.revealedTabId, 't1');
      expect(solta.collapsed, isFalse);
      store.dispose();
    });

    test('lateral escondida volta, e a aba de plugin volta pra lista', () {
      final store = storeWith(['solta']);
      final tab = shell(store, named(store, 'solta'), 't1', 'servidor');
      store.sidebarHidden = true;
      store.sidebarView = 'algum-plugin';

      store.revealTab(tab);

      expect(store.sidebarHidden, isFalse);
      expect(store.sidebarView, isNull);
      store.dispose();
    });

    test('lista já na tela não esconde a lateral', () {
      final store = storeWith(['solta']);
      final tab = shell(store, named(store, 'solta'), 't1', 'servidor');

      store.revealTab(tab);

      expect(store.sidebarHidden, isFalse);
      store.dispose();
    });

    test('busca que esconde a sessão é limpa; a que a acha, mantida', () {
      final store = storeWith(['solta']);
      final tab = shell(store, named(store, 'solta'), 't1', 'servidor');

      store.setQuery('servidor');
      store.revealTab(tab);
      expect(store.query, 'servidor');

      store.setQuery('nada disso');
      store.revealTab(tab);
      expect(store.query, isEmpty);
      expect(store.filtering, isFalse);
      store.dispose();
    });

    test('takeRevealScroll vale uma vez, só pra aparição revelada', () {
      final store = storeWith(['infra']);
      final infra = named(store, 'infra');
      final atrium = store.createWorkspace('ATRIUM', folders: [infra]);
      final uplii = store.createWorkspace('UPLII', folders: [infra]);
      final tab = shell(store, infra, 't1', 'servidor');

      store.revealTab(tab);

      expect(store.takeRevealScroll(tab, uplii), isFalse);
      expect(store.takeRevealScroll(tab, atrium), isTrue);
      expect(store.takeRevealScroll(tab, atrium), isFalse);
      store.dispose();
    });
  });

  testWidgets('um banner no meio dos 2s não segura o destaque', (tester) async {
    final store = storeWith(['solta']);
    final tab = shell(store, named(store, 'solta'), 't1', 'servidor');
    store.revealTab(tab);

    store.showBanner('x');
    await tester.pump(const Duration(seconds: 3));

    expect(store.revealedTabId, isNull);
    store.dispose();
  });

  group('revealTab na lateral', () {
    testWidgets('rola até a sessão num caminho todo dobrado', (tester) async {
      final store = storeWith([for (var i = 0; i < 12; i++) 'repo$i', 'alvo']);
      final alvo = named(store, 'alvo');
      for (var i = 0; i < 12; i++) {
        store.createWorkspace('W$i', folders: [named(store, 'repo$i')]);
      }
      // Por último, pra a linha ficar abaixo da dobra da lateral de 300px.
      final ws = store.createWorkspace('ATRIUM', folders: [alvo]);
      store.moveRootRow(ws, store.sidebarRows.last);
      expect(store.sidebarRows.last, ws);
      final tab = shell(store, alvo, 't1', 'sessão-escondida');
      ws.collapsed = true;
      ws.collapsedFolders.add(alvo.root);
      await pumpSidebar(tester, store, height: 300);
      expect(find.text('sessão-escondida'), findsNothing);

      store.revealTab(tab);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('sessão-escondida'), findsOneWidget);
      final row = tester.getRect(find.text('sessão-escondida'));
      final bar = tester.getRect(find.byType(Sidebar));
      expect(bar.contains(row.topLeft), isTrue);
      expect(bar.contains(row.bottomRight), isTrue);
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
      );
      expect(scroll.position.pixels, greaterThan(0));
      await tester.pump(const Duration(seconds: 3));
      store.dispose();
    });

    testWidgets('o destaque some depois de 2s', (tester) async {
      final store = storeWith(['solta']);
      final tab = shell(store, named(store, 'solta'), 't1', 'servidor');
      await pumpSidebar(tester, store);

      store.revealTab(tab);
      await tester.pump();
      expect(store.revealedTabId, 't1');

      await tester.pump(const Duration(seconds: 3));

      expect(store.revealedTabId, isNull);
      expect(store.revealedWithin, isNull);
      store.dispose();
    });
  });

  testWidgets('o botão do cabeçalho revela a sessão na lateral', (tester) async {
    final store = AppStore();
    final tab = MxTab(
      id: 'tab1',
      folder: Folder(root: '/repo', name: 'meu-repo'),
      kind: TabKind.shell,
      cwd: '/repo',
      branch: '',
      customLabel: 'servidor',
    );
    store.tabs.add(tab);
    store.panes = PaneLeaf(tab.id);
    store.focusedPaneId = tab.id;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 720, height: 320, child: TerminalPane(store: store, tab: tab)),
        ),
      ),
    );

    await tester.tap(find.byTooltip('mostrar na lateral'));
    await tester.pump();

    expect(store.revealedTabId, 'tab1');
    await tester.pump(const Duration(seconds: 3));
    store.dispose();
  });
}
