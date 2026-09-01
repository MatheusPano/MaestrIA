import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';

PaneLeaf leaf(String id) => PaneLeaf(id);

PaneNode row(List<PaneNode> children, [List<double>? weights]) =>
    PaneSplit(PaneAxis.row, children, weights ?? _even(children.length));

PaneNode column(List<PaneNode> children, [List<double>? weights]) =>
    PaneSplit(PaneAxis.column, children, weights ?? _even(children.length));

List<double> _even(int n) => List.filled(n, 1 / n);

List<double> weightsOf(PaneNode? node) => (node as PaneSplit).weights;

PaneAxis axisOf(PaneNode? node) => (node as PaneSplit).axis;

/// Uma sessão registrada na lateral, sem pty nenhum atrás dela.
MxTab session(AppStore store, String id) {
  final tab = MxTab(
    id: id,
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: id,
  );
  store.tabs.add(tab);
  return tab;
}

void main() {
  group('cortar', () {
    test('soltar na borda parte o painel em dois, meio a meio', () {
      final tree = Panes.insert(leaf('a'), tabId: 'b', targetId: 'a', side: DropSide.right);
      expect(axisOf(tree), PaneAxis.row);
      expect(Panes.order(tree), ['a', 'b']);
      expect(weightsOf(tree), [0.5, 0.5]);
    });

    test('e pela borda de cima o corte é deitado, com o novo em cima', () {
      final tree = Panes.insert(leaf('a'), tabId: 'b', targetId: 'a', side: DropSide.top);
      expect(axisOf(tree), PaneAxis.column);
      expect(Panes.order(tree), ['b', 'a']);
    });

    // O que faz três painéis lado a lado serem três painéis lado a lado.
    test('um terceiro no mesmo sentido vira mais uma coluna da fileira', () {
      final tree = Panes.insert(
        row([leaf('a'), leaf('b')]),
        tabId: 'c',
        targetId: 'b',
        side: DropSide.right,
      );
      expect(Panes.order(tree), ['a', 'b', 'c']);
      // Só quem recebeu o drop cede espaço: o vizinho continua com a metade
      // que já tinha.
      expect(weightsOf(tree), [0.5, 0.25, 0.25]);
      expect((tree as PaneSplit).children.every((c) => c is PaneLeaf), isTrue);
    });

    test('no outro sentido, aninha dentro do painel que recebeu', () {
      final tree = Panes.insert(
        row([leaf('a'), leaf('b')]),
        tabId: 'c',
        targetId: 'b',
        side: DropSide.bottom,
      );
      expect(Panes.order(tree), ['a', 'b', 'c']);
      final nested = (tree as PaneSplit).children[1];
      expect(axisOf(nested), PaneAxis.column);
      expect(Panes.order(nested), ['b', 'c']);
    });
  });

  group('fechar', () {
    test('o espaço do painel que saiu vai pros vizinhos, na proporção deles', () {
      final tree = Panes.remove(row([leaf('a'), leaf('b'), leaf('c')], [0.5, 0.25, 0.25]), 'a');
      expect(Panes.order(tree), ['b', 'c']);
      expect(weightsOf(tree), [0.5, 0.5]);
    });

    test('um corte que ficou com um filho só deixa de ser um corte', () {
      final tree = Panes.remove(row([leaf('a'), leaf('b')]), 'b');
      expect(tree, isA<PaneLeaf>());
      expect(Panes.order(tree), ['a']);
    });

    test('e o que desabou dentro de outro do mesmo sentido vira um só', () {
      final tree = Panes.remove(
        row([
          leaf('a'),
          column([
            leaf('b'),
            row([leaf('c'), leaf('d')]),
          ]),
        ]),
        'b',
      );
      expect(Panes.order(tree), ['a', 'c', 'd']);
      // Uma fileira de três, e não uma fileira com um par escondido dentro:
      // o próximo drop precisa cair nela, não numa camada invisível.
      expect((tree as PaneSplit).children.every((c) => c is PaneLeaf), isTrue);
      expect(weightsOf(tree), [0.5, 0.25, 0.25]);
    });

    test('tirar o único painel limpa a tela', () {
      expect(Panes.remove(leaf('a'), 'a'), isNull);
    });
  });

  group('a alça', () {
    test('arrastada, tira de um e dá pro outro', () {
      final tree = row([leaf('a'), leaf('b')]) as PaneSplit;
      Panes.resize(tree, 0, 100, 1000);
      expect(weightsOf(tree), [0.6, 0.4]);
    });

    test('não espreme um painel até ele sumir', () {
      final tree = row([leaf('a'), leaf('b')]) as PaneSplit;
      Panes.resize(tree, 0, -10000, 1000);
      // O mínimo é [Panes.minWidth] em pixels: um painel de largura zero não
      // teria borda pra você agarrar de volta.
      expect(tree.weights[0], closeTo(Panes.minWidth / 1000, 0.001));
    });
  });

  group('o disco', () {
    test('a árvore volta como saiu', () {
      final saved = ['a', 'b', 'c'];
      final tree = row(
        [
          leaf('a'),
          column([leaf('b'), leaf('c')], [0.7, 0.3]),
        ],
        [0.4, 0.6],
      );

      final json = Panes.toJson(tree, saved.indexOf);
      final back = Panes.fromJson(json, (i) => saved[i]);

      expect(Panes.order(back), ['a', 'b', 'c']);
      expect(weightsOf(back), [0.4, 0.6]);
      expect(weightsOf((back as PaneSplit).children[1]), [0.7, 0.3]);
    });

    test('a sessão que não voltou não deixa um buraco no lugar dela', () {
      final tree = row([leaf('a'), leaf('b')]);
      // 'b' não pôde ser restaurada -- a pasta sumiu, digamos.
      final json = Panes.toJson(tree, (id) => id == 'a' ? 0 : -1);
      final back = Panes.fromJson(json, (i) => 'a');
      expect(back, isA<PaneLeaf>());
      expect(Panes.order(back), ['a']);
    });
  });

  group('arrastar da lateral', () {
    test('pra borda de um painel, abre um painel do lado', () {
      final store = AppStore();
      final a = session(store, 'a');
      final b = session(store, 'b');
      store.panes = leaf(a.id);
      store.focusedPaneId = a.id;

      store.dropTab(b, target: a, side: DropSide.right);

      expect(Panes.order(store.panes), ['a', 'b']);
      // O foco vai com a sessão que você acabou de largar: é nela que você vai
      // digitar.
      expect(store.focusedPaneId, 'b');
      store.dispose();
    });

    test('uma sessão que já estava na tela muda de lugar, não duplica', () {
      final store = AppStore();
      final a = session(store, 'a');
      session(store, 'b');
      final c = session(store, 'c');
      store.panes = row([leaf('a'), leaf('b'), leaf('c')]);
      store.focusedPaneId = 'a';

      store.dropTab(a, target: c, side: DropSide.right);

      expect(Panes.order(store.panes), ['b', 'c', 'a']);
      store.dispose();
    });

    test('no meio, toma o lugar — e quem saiu continua viva na lateral', () {
      final store = AppStore();
      final a = session(store, 'a');
      final c = session(store, 'c');
      store.panes = row([leaf('a'), leaf('b')]);
      store.focusedPaneId = 'a';

      store.dropTab(c, target: a, side: DropSide.center);

      expect(Panes.order(store.panes), ['c', 'b']);
      expect(store.tabs, contains(a));
      expect(a.term.exited, isFalse);
      store.dispose();
    });

    test('clicar na lateral troca o painel em foco em vez de abrir outro', () {
      final store = AppStore();
      session(store, 'a');
      final b = session(store, 'b');
      final c = session(store, 'c');
      store.panes = row([leaf('a'), leaf('b')]);
      store.focusedPaneId = 'b';

      store.select(c);

      expect(Panes.order(store.panes), ['a', 'c']);
      expect(store.isOpen(b), isFalse);
      store.dispose();
    });
  });
}
