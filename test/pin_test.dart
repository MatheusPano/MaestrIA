import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/docs.dart';
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

    test('a direita presa: fechar o da esquerda e clicar reabre na esquerda', () {
      final store = storeWith(['solto', 'a', 'b', 'outro']);
      store.panes = PaneSplit(PaneAxis.row, [
        PaneLeaf('solto'),
        PaneSplit(PaneAxis.column, [PaneLeaf('a'), PaneLeaf('b')], [0.5, 0.5]),
      ], [0.4, 0.6]);
      store.togglePin(tab(store, 'a'));
      store.togglePin(tab(store, 'b'));
      store.focusedPaneId = 'a';

      store.dismiss(tab(store, 'solto'));
      store.select(tab(store, 'outro'));

      final root = store.panes! as PaneSplit;
      expect(root.axis, PaneAxis.row);
      expect(root.weights, [0.4, 0.6]);
      expect((root.children.first as PaneLeaf).tabId, 'outro');
      expect(Panes.order(root.children.last), ['a', 'b']);
      expect(store.isPinned(tab(store, 'a')), isTrue);
      expect(store.isPinned(tab(store, 'b')), isTrue);
    });

    test('encerrar o solto também guarda o lugar dele', () {
      final store = storeWith(['solto', 'fixo', 'outro']);
      store.panes = PaneSplit(PaneAxis.row, [PaneLeaf('solto'), PaneLeaf('fixo')], [0.5, 0.5]);
      store.togglePin(tab(store, 'fixo'));

      store.closeTab(tab(store, 'solto'));
      store.select(tab(store, 'outro'));

      expect(Panes.order(store.panes), ['outro', 'fixo']);
    });

    test('a tela mudou depois que o solto saiu: o buraco antigo não volta', () {
      final store = storeWith(['solto', 'a', 'b', 'outro']);
      store.panes = PaneSplit(PaneAxis.row, [PaneLeaf('solto'), PaneLeaf('a')], [0.5, 0.5]);
      store.togglePin(tab(store, 'a'));
      store.dismiss(tab(store, 'solto'));
      // Um arraste depois: a tela já não é a que o buraco deixou.
      store.dropTab(tab(store, 'b'), target: tab(store, 'a'), side: DropSide.bottom);
      store.togglePin(tab(store, 'b'));
      store.focusedPaneId = 'a';

      store.select(tab(store, 'outro'));

      // Na borda da tela, sem cortar nenhum dos presos ao meio.
      final root = store.panes! as PaneSplit;
      expect(root.axis, PaneAxis.row);
      expect(Panes.order(root.children.first), ['a', 'b']);
      expect((root.children.last as PaneLeaf).tabId, 'outro');
    });

    test('com todos presos e sem buraco, a sessão entra na borda, não no meio de um preso', () {
      final store = storeWith(['a', 'b', 'novo']);
      store.panes = PaneSplit(PaneAxis.column, [PaneLeaf('a'), PaneLeaf('b')], [0.5, 0.5]);
      store.togglePin(tab(store, 'a'));
      store.togglePin(tab(store, 'b'));
      store.focusedPaneId = 'a';

      store.select(tab(store, 'novo'));

      final root = store.panes! as PaneSplit;
      expect(root.axis, PaneAxis.row);
      expect(Panes.order(root.children.first), ['a', 'b']);
      expect((root.children.last as PaneLeaf).tabId, 'novo');
    });

    test('abrir algo "ao lado" de um preso corta o solto, não o preso', () {
      final store = storeWith(['solto', 'fixo']);
      store.panes = PaneSplit(PaneAxis.row, [PaneLeaf('solto'), PaneLeaf('fixo')], [0.5, 0.5]);
      store.togglePin(tab(store, 'fixo'));
      store.focusedPaneId = 'fixo';

      final doc = store.showDoc(MxDoc.file('/repo/README.md'), from: tab(store, 'fixo'));

      expect(Panes.order(store.panes), ['solto', doc.id, 'fixo']);
      final root = store.panes! as PaneSplit;
      expect(root.weights.last, 0.5);
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
