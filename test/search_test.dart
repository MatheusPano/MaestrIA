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

MxTab panel(
  AppStore store,
  String name, {
  Folder? folder,
  Project? project,
  TabKind kind = TabKind.claude,
  ClaudeStatus? status,
}) {
  final where = folder ?? store.folders.first;
  final tab = MxTab(
    id: name,
    folder: where,
    kind: kind,
    cwd: where.root,
    branch: '',
    customLabel: name,
  );
  tab.projectId = project?.id;
  if (status != null) tab.hooks.status = status;
  store.tabs.add(tab);
  return tab;
}

/// Wide enough for the header to keep the word "pasta" beside the + — see
/// worktrees_test on why the test font needs the room.
///
/// Com o [AnimatedBuilder], que os outros testes de lateral não precisam: aqui
/// o store muda *depois* do primeiro frame, digitado no campo, e sem escutá-lo
/// a lateral ficaria mostrando a lista de antes — que é o que `main.dart` faz
/// um nível acima.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 660,
        height: 700,
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) => Sidebar(store: store),
        ),
      ),
    ),
  ),
);

Future<void> search(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('a busca', () {
    test('acha a sessão pelo nome que você deu a ela', () {
      final store = storeWithFolder();
      final renamed = panel(store, 'permissão do drive');
      final other = panel(store, 'migração do banco');

      store.setQuery('drive');
      expect(store.matches(renamed), isTrue);
      expect(store.matches(other), isFalse);
      store.dispose();
    });

    // O que a lateral mostra em cada linha é o que a busca tem que aceitar:
    // ninguém procura uma sessão pelo id dela.
    test('acha também pela pasta, pelo projeto e pela branch', () {
      final store = storeWithFolder();
      final project = store.addProject(store.folders.first, 'permissão do google');
      final tab = panel(store, 'um', project: project)..branch = 'feature/TASK#47730';

      for (final term in ['meu-repo', 'google', 'TASK#47730', 'shell']) {
        store.setQuery(term);
        expect(store.matches(tab), term == 'shell' ? isFalse : isTrue, reason: term);
      }
      store.dispose();
    });

    test('dois termos valem em qualquer ordem', () {
      final store = storeWithFolder();
      final tab = panel(store, 'permissão do google');
      store.setQuery('google perm');
      expect(store.matches(tab), isTrue);
      store.setQuery('google banco');
      expect(store.matches(tab), isFalse);
      store.dispose();
    });
  });

  group('os filtros', () {
    test('por pasta, deixam só as sessões de lá', () {
      final store = storeWithFolder();
      final elsewhere = Folder(root: '/outro', name: 'outro-repo');
      store.folders.add(elsewhere);
      final mine = panel(store, 'aqui');
      final theirs = panel(store, 'longe', folder: elsewhere);

      store.toggleFilterFolder(store.folders.first);
      expect(store.matches(mine), isTrue);
      expect(store.matches(theirs), isFalse);
      store.dispose();
    });

    // Pasta e projeto são a mesma pergunta — o "onde" — e somam: marcar um repo
    // e um projeto de outro repo mostra os dois, não a interseção vazia.
    test('pasta e projeto somam entre si', () {
      final store = storeWithFolder();
      final elsewhere = Folder(root: '/outro', name: 'outro-repo');
      store.folders.add(elsewhere);
      final project = store.addProject(elsewhere, 'permissão do google');
      final here = panel(store, 'aqui');
      final there = panel(store, 'lá', folder: elsewhere, project: project);
      final neither = panel(store, 'nem', folder: elsewhere);

      store.toggleFilterFolder(store.folders.first);
      store.toggleFilterProject(project);
      expect(store.matches(here), isTrue);
      expect(store.matches(there), isTrue);
      expect(store.matches(neither), isFalse);
      store.dispose();
    });

    // Dentro de um grupo as opções somam, entre grupos elas cortam.
    test('tipo e estado se cruzam; dois estados se somam', () {
      final store = storeWithFolder();
      final waiting = panel(store, 'esperando', status: ClaudeStatus.waitingPermission);
      final working = panel(store, 'trabalhando', status: ClaudeStatus.working);
      final shell = panel(store, 'terminal', kind: TabKind.shell);

      store.toggleFilter(MxFilter.claude);
      store.toggleFilter(MxFilter.waiting);
      expect(store.matches(waiting), isTrue);
      expect(store.matches(working), isFalse);
      expect(store.matches(shell), isFalse);

      store.toggleFilter(MxFilter.working);
      expect(store.matches(waiting), isTrue);
      expect(store.matches(working), isTrue);
      store.dispose();
    });

    // O tique é você dizendo que essa já foi: uma sessão guardada não é uma
    // pendência, mesmo parada num pedido de permissão.
    test('concluída sai de "esperando você"', () {
      final store = storeWithFolder();
      final tab = panel(store, 'pronta', status: ClaudeStatus.waitingPermission)..done = true;
      store.toggleFilter(MxFilter.waiting);
      expect(store.matches(tab), isFalse);
      store.toggleFilter(MxFilter.waiting);
      store.toggleFilter(MxFilter.finished);
      expect(store.matches(tab), isTrue);
      store.dispose();
    });

    test('limpar devolve a lista inteira', () {
      final store = storeWithFolder();
      panel(store, 'um');
      store.setQuery('nada com esse nome');
      store.toggleFilter(MxFilter.shell);
      expect(store.filtering, isTrue);
      expect(store.hits, isEmpty);

      store.clearSearch();
      expect(store.filtering, isFalse);
      expect(store.query, '');
      expect(store.activeFilters, 0);
      expect(store.hits, hasLength(1));
      store.dispose();
    });

  });

  group('a lateral, procurando', () {
    testWidgets('deixa na tela só o que casa', (tester) async {
      final store = storeWithFolder();
      panel(store, 'permissão do drive');
      panel(store, 'migração do banco');

      await pumpSidebar(tester, store);
      await search(tester, 'drive');
      expect(find.text('permissão do drive'), findsOneWidget);
      expect(find.text('migração do banco'), findsNothing);
      store.dispose();
    });

    testWidgets('abre o que estava dobrado, e não desfaz a dobra', (tester) async {
      final store = storeWithFolder();
      panel(store, 'permissão do drive');
      store.toggleCollapsed(store.folders.first);

      await pumpSidebar(tester, store);
      expect(find.text('permissão do drive'), findsNothing);

      await search(tester, 'drive');
      expect(find.text('permissão do drive'), findsOneWidget);
      // A dobra é uma escolha sua: ela não vale enquanto se procura, e continua
      // valendo depois.
      expect(store.folders.first.collapsed, isTrue);
      await search(tester, '');
      expect(find.text('permissão do drive'), findsNothing);
      store.dispose();
    });

    testWidgets('esconde a pasta que não tem nada a mostrar', (tester) async {
      final store = storeWithFolder();
      final elsewhere = Folder(root: '/outro', name: 'outro-repo');
      store.folders.add(elsewhere);
      panel(store, 'permissão do drive');
      panel(store, 'migração do banco', folder: elsewhere);

      await pumpSidebar(tester, store);
      await search(tester, 'drive');
      expect(find.text('meu-repo'), findsOneWidget);
      expect(find.text('outro-repo'), findsNothing);
      store.dispose();
    });

    // As worktrees são o que o repo *é*, não uma sessão que você procura.
    testWidgets('recolhe a gaveta de worktrees', (tester) async {
      final store = storeWithFolder();
      store.worktrees['/repo'] = [
        WorktreeInfo(path: '/repo', branch: 'master', isMain: true),
        WorktreeInfo(path: '/repo/wt/TASK-47730', branch: 'feature/TASK#47730', isMain: false),
      ];
      panel(store, 'permissão do drive');

      await pumpSidebar(tester, store);
      expect(find.text('worktrees'), findsOneWidget);
      await search(tester, 'drive');
      expect(find.text('worktrees'), findsNothing);
      store.dispose();
    });

    testWidgets('sem achado, oferece a saída — e ela funciona', (tester) async {
      final store = storeWithFolder();
      panel(store, 'permissão do drive');

      await pumpSidebar(tester, store);
      await search(tester, 'banco');
      expect(find.text('permissão do drive'), findsNothing);
      expect(find.textContaining('nenhuma sessão'), findsOneWidget);

      await tester.tap(find.text('mostrar tudo'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(store.filtering, isFalse);
      expect(find.text('permissão do drive'), findsOneWidget);
      store.dispose();
    });

    // Estreita, não cabem o campo e a palavra "pasta" — e é o campo que fica.
    // Um estouro aqui é uma barra de ferramentas que vira uma faixa amarela.
    testWidgets('estreita, sobra o + sozinho e nada estoura', (tester) async {
      final store = storeWithFolder();
      panel(store, 'permissão do drive');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: AppStore.minSidebar,
              height: 700,
              child: AnimatedBuilder(
                animation: store,
                builder: (context, _) => Sidebar(store: store),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('pasta'), findsNothing);
      expect(find.byTooltip('adicionar uma pasta ao cockpit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      store.dispose();
    });

    // O atalho não sabe se a lateral está montada; ele fala com o campo.
    testWidgets('o atalho manda o teclado pro campo', (tester) async {
      final store = storeWithFolder();
      await pumpSidebar(tester, store);
      expect(SidebarSearch.focus.hasFocus, isFalse);

      SidebarSearch.reveal();
      await tester.pump();
      expect(SidebarSearch.focus.hasFocus, isTrue);
      SidebarSearch.focus.unfocus();
      store.dispose();
    });
  });
}
