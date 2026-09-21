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

List<String> folderOrder(AppStore store) => store.folders.map((f) => f.name).toList();

/// Carimba as pastas [names] como vindas do mesmo `.code-workspace`, que é o
/// que faz a lateral desenhá-las numa seção só. Ver `AppStore.importWorkspace`.
Workspace section(AppStore store, List<String> names, {String name = 'cefis'}) {
  final ws = Workspace(path: '/repos/$name.code-workspace', name: name);
  store.workspaces.add(ws);
  for (final f in store.folders.where((f) => names.contains(f.name))) {
    f.workspace = ws.path;
  }
  return ws;
}

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

  // A ordem das pastas é a ordem em que foram adicionadas até alguém arrumá-la:
  // a que você abriu agora entra em último, e é de lá que ela sobe.
  group('reordenar pastas', () {
    test('uma pasta solta na vaga da linha em que foi solta', () {
      final store = storeWithFolders(['um', 'dois', 'tres', 'quatro']);
      store.moveRow(store.folders[3], store.folders[1]);
      expect(folderOrder(store), ['um', 'quatro', 'dois', 'tres']);
    });

    test('e descendo, a mesma vaga', () {
      final store = storeWithFolders(['um', 'dois', 'tres', 'quatro']);
      store.moveRow(store.folders[0], store.folders[2]);
      expect(folderOrder(store), ['dois', 'tres', 'um', 'quatro']);
    });

    test('soltar uma pasta nela mesma não muda nada', () {
      final store = storeWithFolders(['um', 'dois']);
      store.moveRow(store.folders[1], store.folders[1]);
      expect(folderOrder(store), ['um', 'dois']);
    });

    // A seção é uma linha só na tela; as pastas dela não se separam no caminho.
    test('uma seção viaja inteira', () {
      final store = storeWithFolders(['um', 'api', 'web', 'dois']);
      final ws = section(store, ['api', 'web']);
      store.moveRow(ws, store.folders.first);
      expect(folderOrder(store), ['api', 'web', 'um', 'dois']);
    });

    test('e uma pasta solta passa por cima da seção inteira', () {
      final store = storeWithFolders(['um', 'api', 'web', 'dois']);
      final ws = section(store, ['api', 'web']);
      store.moveRow(store.folders.last, ws);
      expect(folderOrder(store), ['um', 'dois', 'api', 'web']);
    });

    test('dentro da seção, a pasta se arruma entre as irmãs', () {
      final store = storeWithFolders(['api', 'web', 'app']);
      section(store, ['api', 'web', 'app']);
      store.moveRow(store.folders[2], store.folders[0]);
      expect(folderOrder(store), ['app', 'api', 'web']);
    });

    // Tirar a pasta do workspace é outra operação, e tem menu. Arrastar arruma.
    test('uma pasta de workspace não sai dele arrastando', () {
      final store = storeWithFolders(['api', 'web', 'solta']);
      section(store, ['api', 'web']);
      expect(store.canMoveRow(store.folders[0], store.folders[2]), isFalse);
      store.moveRow(store.folders[0], store.folders[2]);
      expect(folderOrder(store), ['api', 'web', 'solta']);
    });
  });

  group('arrastar uma pasta', () {
    testWidgets('pelo cabeçalho, pra vaga da linha em que se soltou', (tester) async {
      final store = storeWithFolders(['alfa', 'beta', 'gama']);
      await pumpSidebar(tester, store);
      await dragRow(tester, 'gama', 'alfa');
      expect(folderOrder(store), ['gama', 'alfa', 'beta']);
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
      expect(store.folders[1].collapsed, isTrue);
      expect(folderOrder(store), ['alfa', 'beta']);
      store.dispose();
    });
  });
}
