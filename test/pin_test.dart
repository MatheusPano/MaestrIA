import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';

/// Sessões montadas à mão, sem processo: o que está em teste é qual lugar da
/// tela o clique na lateral troca.
AppStore storeWith(List<String> names) {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo');
  for (final name in names) {
    store.tabs.add(
      MxTab(id: name, folder: folder, kind: TabKind.claude, cwd: '/repo', branch: ''),
    );
  }
  return store;
}

MxTab tab(AppStore store, String id) => store.tabById(id)!;

void main() {
  group('painel preso', () {
    test('com o preso em foco, o clique troca o outro painel', () {
      final store = storeWith(['fixo', 'solto', 'tres']);
      store.panes = PaneSplit(PaneAxis.row, [PaneLeaf('fixo'), PaneLeaf('solto')], [0.5, 0.5]);
      store.focusedPaneId = 'fixo';
      store.togglePin(tab(store, 'fixo'));

      store.select(tab(store, 'tres'));

      expect(Panes.order(store.panes), ['fixo', 'tres']);
      expect(store.focusedPaneId, 'tres');
      expect(store.isPinned(tab(store, 'fixo')), isTrue);
    });

    test('com o solto em foco, continua trocando ele', () {
      final store = storeWith(['fixo', 'solto', 'tres']);
      store.panes = PaneSplit(PaneAxis.row, [PaneLeaf('fixo'), PaneLeaf('solto')], [0.5, 0.5]);
      store.focusedPaneId = 'solto';
      store.togglePin(tab(store, 'fixo'));

      store.select(tab(store, 'tres'));

      expect(Panes.order(store.panes), ['fixo', 'tres']);
    });

    test('com todos presos, a sessão abre ao lado em vez de trocar', () {
      final store = storeWith(['fixo', 'novo']);
      store.panes = PaneLeaf('fixo');
      store.focusedPaneId = 'fixo';
      store.togglePin(tab(store, 'fixo'));

      store.select(tab(store, 'novo'));

      expect(Panes.order(store.panes), ['fixo', 'novo']);
      expect(store.focusedPaneId, 'novo');
    });

    test('sair da tela solta o painel', () {
      final store = storeWith(['fixo', 'solto']);
      store.panes = PaneSplit(PaneAxis.row, [PaneLeaf('fixo'), PaneLeaf('solto')], [0.5, 0.5]);
      store.focusedPaneId = 'fixo';
      store.togglePin(tab(store, 'fixo'));

      store.dismiss(tab(store, 'fixo'));

      expect(tab(store, 'fixo').pinned, isFalse);
      expect(store.isPinned(tab(store, 'fixo')), isFalse);
    });

    test('soltar em cima do preso troca o conteúdo e o lugar segue preso', () {
      final store = storeWith(['fixo', 'solto', 'tres']);
      store.panes = PaneSplit(PaneAxis.row, [PaneLeaf('fixo'), PaneLeaf('solto')], [0.5, 0.5]);
      store.togglePin(tab(store, 'fixo'));

      store.dropTab(tab(store, 'tres'), target: tab(store, 'fixo'), side: DropSide.center);

      expect(Panes.order(store.panes), ['tres', 'solto']);
      expect(store.isPinned(tab(store, 'tres')), isTrue);
      expect(tab(store, 'fixo').pinned, isFalse);
    });

    test('o preso volta preso depois de fechar a janela', () {
      final store = storeWith(['fixo']);
      store.panes = PaneLeaf('fixo');
      store.togglePin(tab(store, 'fixo'));

      expect(tab(store, 'fixo').toJson()['pinned'], isTrue);
      // A receita é o que um grupo guarda, e preso é da tela, não do grupo.
      expect(tab(store, 'fixo').recipe.containsKey('pinned'), isFalse);
    });
  });
}
