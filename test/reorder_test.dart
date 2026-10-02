import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';

/// One folder with a panel per name, in that order.
AppStore storeWith(List<String> names) {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo')
    ..isRepo = true
    ..branch = 'master';
  store.folders.add(folder);
  for (final name in names) {
    store.tabs.add(
      MxTab(
        id: name,
        folder: folder,
        kind: TabKind.claude,
        cwd: '/repo',
        branch: '',
        customLabel: name,
      ),
    );
  }
  return store;
}

List<String?> order(AppStore store) => store.tabs.map((t) => t.customLabel).toList();

/// Wide enough that the add-row chips fit — see worktrees_test.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 660, height: 700, child: Sidebar(store: store)),
    ),
  ),
);

/// Pick the row up and drop it on the other one, the way a mouse would.
Future<void> dragRow(WidgetTester tester, String from, String onto) async {
  // Both centres before the drag starts: while a row is in the air its text
  // is on screen twice, once in the list and once under the pointer.
  final start = tester.getCenter(find.text(from));
  final target = tester.getCenter(find.text(onto));
  final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  // Never pumpAndSettle here: a Claude row's mark pulses forever, so there is
  // nothing to settle into.
  await tester.pump();
}

/// Uma pasta por nome, na ordem em que a lateral as desenha.
AppStore storeWithFolders(List<String> names) {
  final store = AppStore();
  for (final name in names) {
    store.folders.add(Folder(root: '/repos/$name', name: name));
  }
  return store;
}

/// A raiz da lateral, por nome: `ws:<nome>` pros workspaces.
List<String> rowOrder(AppStore store) => [
  for (final r in store.sidebarRows) r is Workspace ? 'ws:${r.name}' : (r as Folder).name,
];

Folder named(AppStore store, String name) => store.folders.firstWhere((f) => f.name == name);

/// Um workspace com as pastas [names], criado como a lateral cria.
Workspace section(AppStore store, List<String> names, {String name = 'cefis'}) =>
    store.createWorkspace(name, folders: [for (final n in names) named(store, n)]);

RowPlace root(SidebarRow row) => (row: row, within: null);
RowPlace inside(Folder f, Workspace w) => (row: f, within: w);

void main() {
  group('reordering panels', () {
    // The panels of one folder are a subsequence of the one list, not a slice
    // of it, so a move has to leave everyone else exactly where they were.
    test('a panel dropped on a row below takes that row\'s place', () {
      final store = storeWith(['um', 'dois', 'tres', 'quatro']);
      store.moveTab(store.tabs[0], store.tabs[2]);
      expect(order(store), ['dois', 'tres', 'um', 'quatro']);
    });

    test('and dropped on a row above, the same', () {
      final store = storeWith(['um', 'dois', 'tres', 'quatro']);
      store.moveTab(store.tabs[3], store.tabs[1]);
      expect(order(store), ['um', 'quatro', 'dois', 'tres']);
    });

    test('dropping a panel on itself changes nothing', () {
      final store = storeWith(['um', 'dois', 'tres']);
      store.moveTab(store.tabs[1], store.tabs[1]);
      expect(order(store), ['um', 'dois', 'tres']);
    });

    test('a panel that is no longer in the list is not moved', () {
      final store = storeWith(['um', 'dois']);
      final gone = storeWith(['fantasma']).tabs.single;
      store.moveTab(gone, store.tabs[0]);
      expect(order(store), ['um', 'dois']);
    });
  });

  // Each of these ends on `store.dispose()`: a drop schedules the debounced
  // write of the layout, and a widget test refuses to end with a timer still
  // on the clock. Disposing the store cancels it.
  group('dragging a panel', () {
    testWidgets('down the list lands it on the row it was dropped on', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpSidebar(tester, store);
      await dragRow(tester, 'um', 'tres');
      expect(order(store), ['dois', 'tres', 'um']);
      store.dispose();
    });

    testWidgets('up the list, the same', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpSidebar(tester, store);
      await dragRow(tester, 'tres', 'um');
      expect(order(store), ['tres', 'um', 'dois']);
      store.dispose();
    });

    testWidgets('onto a panel of another folder, nothing moves', (tester) async {
      final store = storeWith(['um', 'dois']);
      final other = Folder(root: '/outro', name: 'outro-repo');
      store.folders.add(other);
      store.tabs.add(
        MxTab(
          id: 'longe',
          folder: other,
          kind: TabKind.claude,
          cwd: '/outro',
          branch: '',
          customLabel: 'longe',
        ),
      );
      await pumpSidebar(tester, store);
      await dragRow(tester, 'longe', 'um');
      expect(order(store), ['um', 'dois', 'longe']);
      store.dispose();
    });

    // A mouse drag starts after a single pixel, so a click whose pointer
    // drifted would otherwise be swallowed by a drag that goes nowhere.
    testWidgets('a click that drifted a pixel still selects it', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpSidebar(tester, store);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('dois')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 3));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(store.focusedPaneId, 'dois');
      expect(order(store), ['um', 'dois', 'tres']);
      store.dispose();
    });
  });

  group('reordenar a raiz', () {
    test('uma pasta solta na vaga da linha em que foi solta', () {
      final store = storeWithFolders(['um', 'dois', 'tres', 'quatro']);
      store.drop(root(named(store, 'quatro')), root(named(store, 'dois')));
      expect(rowOrder(store), ['um', 'quatro', 'dois', 'tres']);
      store.dispose();
    });

    test('e descendo, a mesma vaga', () {
      final store = storeWithFolders(['um', 'dois', 'tres', 'quatro']);
      store.drop(root(named(store, 'um')), root(named(store, 'tres')));
      expect(rowOrder(store), ['dois', 'tres', 'um', 'quatro']);
      store.dispose();
    });

    test('soltar uma pasta nela mesma não muda nada', () {
      final store = storeWithFolders(['um', 'dois']);
      expect(store.canDrop(root(named(store, 'dois')), root(named(store, 'dois'))), isFalse);
      store.drop(root(named(store, 'dois')), root(named(store, 'dois')));
      expect(rowOrder(store), ['um', 'dois']);
      store.dispose();
    });

    test('uma seção viaja inteira', () {
      final store = storeWithFolders(['um', 'api', 'web', 'dois']);
      final ws = section(store, ['api', 'web']);
      store.drop(root(ws), root(named(store, 'um')));
      expect(rowOrder(store), ['ws:cefis', 'um', 'dois']);
      expect(store.foldersOf(ws).map((f) => f.name), ['api', 'web']);
      store.dispose();
    });

    test('e uma pasta solta passa por cima da seção inteira', () {
      final store = storeWithFolders(['um', 'dois']);
      store.folders.addAll([Folder(root: '/repos/api', name: 'api')]);
      final ws = section(store, ['api']);
      store.drop(root(named(store, 'um')), root(ws));
      expect(rowOrder(store), ['dois', 'ws:cefis', 'um']);
      store.dispose();
    });

    test('uma seção não entra no meio de outra', () {
      final store = storeWithFolders(['api', 'web']);
      final a = section(store, ['api'], name: 'a');
      final b = section(store, ['web'], name: 'b');
      expect(store.canDrop(root(a), inside(named(store, 'web'), b)), isFalse);
      expect(store.canDrop(root(a), root(b), into: true), isFalse);
      store.dispose();
    });
  });

  group('dentro de um workspace', () {
    test('a pasta se arruma entre as irmãs', () {
      final store = storeWithFolders(['api', 'web', 'app']);
      final ws = section(store, ['api', 'web', 'app']);
      store.drop(inside(named(store, 'app'), ws), inside(named(store, 'api'), ws));
      expect(store.foldersOf(ws).map((f) => f.name), ['app', 'api', 'web']);
      store.dispose();
    });

    test('solta numa linha da raiz, sai do workspace e fica naquela vaga', () {
      final store = storeWithFolders(['api', 'web', 'solta']);
      final ws = section(store, ['api', 'web']);
      store.drop(inside(named(store, 'api'), ws), root(named(store, 'solta')));
      expect(store.foldersOf(ws).map((f) => f.name), ['web']);
      // O workspace novo entrou no fim da raiz; a pasta que sai dele fica na
      // vaga da linha em que caiu, empurrando-a pra baixo.
      expect(rowOrder(store), ['api', 'solta', 'ws:cefis']);
      store.dispose();
    });

    test('uma pasta solta sobre uma pasta de dentro entra naquela vaga', () {
      final store = storeWithFolders(['api', 'web', 'solta']);
      final ws = section(store, ['api', 'web']);
      store.drop(root(named(store, 'solta')), inside(named(store, 'web'), ws));
      expect(store.foldersOf(ws).map((f) => f.name), ['api', 'solta', 'web']);
      expect(rowOrder(store), ['ws:cefis']);
      store.dispose();
    });

    test('solta no meio do cabeçalho de outro workspace, muda de workspace', () {
      final store = storeWithFolders(['api', 'web']);
      final a = section(store, ['api'], name: 'a');
      final b = section(store, ['web'], name: 'b');
      store.drop(inside(named(store, 'api'), a), root(b), into: true);
      expect(store.foldersOf(a), isEmpty);
      expect(store.foldersOf(b).map((f) => f.name), ['web', 'api']);
      store.dispose();
    });

    test('uma pasta solta no meio do cabeçalho entra no workspace', () {
      final store = storeWithFolders(['api', 'solta']);
      final ws = section(store, ['api']);
      store.drop(root(named(store, 'solta')), root(ws), into: true);
      expect(store.foldersOf(ws).map((f) => f.name), ['api', 'solta']);
      expect(rowOrder(store), ['ws:cefis']);
      store.dispose();
    });

    test('no meio do cabeçalho do próprio workspace, nada acontece', () {
      final store = storeWithFolders(['api']);
      final ws = section(store, ['api']);
      expect(store.canDrop(inside(named(store, 'api'), ws), root(ws), into: true), isFalse);
      store.dispose();
    });

    // A borda do cabeçalho é reordenar, não entrar.
    test('na borda do cabeçalho, uma pasta solta só reordena', () {
      final store = storeWithFolders(['solta', 'api']);
      final ws = section(store, ['api']);
      store.drop(root(named(store, 'solta')), root(ws));
      expect(store.foldersOf(ws).map((f) => f.name), ['api']);
      expect(rowOrder(store), ['ws:cefis', 'solta']);
      store.dispose();
    });
  });

  group('arrastar uma pasta', () {
    testWidgets('pelo cabeçalho, pra vaga da linha em que se soltou', (tester) async {
      final store = storeWithFolders(['alfa', 'beta', 'gama']);
      await pumpSidebar(tester, store);
      await dragRow(tester, 'gama', 'alfa');
      expect(rowOrder(store), ['gama', 'alfa', 'beta']);
      store.dispose();
    });

    // O clique que o arrasto engoliu: no cabeçalho, clicar dobra a pasta.
    testWidgets('um clique que escorregou um pixel ainda dobra a pasta', (tester) async {
      final store = storeWithFolders(['alfa', 'beta']);
      await pumpSidebar(tester, store);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('beta')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 3));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(named(store, 'beta').collapsed, isTrue);
      expect(rowOrder(store), ['alfa', 'beta']);
      store.dispose();
    });
  });
}
