/// Onde os painéis moram: uma árvore de divisões, não uma lista.
///
/// A tela era dois slots com nome — o da esquerda e o da direita —, e isso é
/// o que dava pra dizer sobre ela. Aqui o que existe é uma árvore: uma folha
/// é um painel na tela, um nó é um corte com os pedaços dentro. Cortar um
/// painel ao meio é trocar a folha por um nó de dois; fechar um painel é tirar
/// a folha e deixar o nó desabar de volta no que sobrou. Nenhuma das duas
/// operações sabe quantos painéis existem, que é justamente o que o modelo
/// antigo não conseguia não saber.
///
/// Puro Dart de propósito: quem desenha isso é a `ui/panes.dart`, e as regras
/// de corte, colapso e proporção dá pra testar sem levantar um widget.
library;

/// Como um corte arruma os filhos: lado a lado, ou um debaixo do outro.
enum PaneAxis { row, column }

/// Onde o painel arrastado cai, em relação ao painel que recebeu o drop.
enum DropSide {
  left,
  right,
  top,
  bottom,

  /// No meio: o painel toma o lugar do que estava ali. O que saiu volta pra
  /// lateral vivo — soltar em cima é trocar de painel, não fechar um.
  center;

  PaneAxis get axis => this == left || this == right ? PaneAxis.row : PaneAxis.column;

  /// Se o recém-chegado fica antes do painel em que caiu.
  bool get leading => this == left || this == top;
}

/// Um nó da árvore: ou um painel na tela, ou um corte entre outros nós.
sealed class PaneNode {
  const PaneNode();
}

/// Um painel na tela, dito pelo id da sessão que ele mostra.
class PaneLeaf extends PaneNode {
  PaneLeaf(this.tabId);

  /// Mutável: soltar uma sessão no meio de um painel é exatamente este campo
  /// mudando — o retângulo continua onde estava, com outra coisa dentro.
  String tabId;
}

/// Um corte: os pedaços, e quanto do espaço cabe a cada um.
class PaneSplit extends PaneNode {
  /// Copia as duas listas: um corte cresce e encolhe a cada painel aberto ou
  /// fechado, e uma `List.filled` chegando de fora travaria isso na primeira
  /// divisão.
  PaneSplit(this.axis, List<PaneNode> children, List<double> weights)
    : children = List.of(children),
      weights = List.of(weights);

  final PaneAxis axis;
  final List<PaneNode> children;

  /// Uma fatia por filho, somando 1. Guardadas como fração e não em pixels
  /// porque a janela muda de tamanho e a divisão que você fez não deveria:
  /// "metade e metade" continua metade e metade num monitor maior.
  final List<double> weights;
}

/// As operações da árvore. Todas trabalham por id de sessão, nunca por
/// referência ao nó — o que a interface tem em mãos quando você solta o mouse
/// é um painel, e achar o nó dele é problema daqui.
abstract final class Panes {
  /// O menor painel que ainda é um painel. Largura e altura são números
  /// diferentes porque um painel estreito perde o cabeçalho inteiro, enquanto
  /// um baixo continua legível com três linhas de terminal.
  static const double minWidth = 240;
  static const double minHeight = 140;

  static double minFor(PaneAxis axis) => axis == PaneAxis.row ? minWidth : minHeight;

  /// Os painéis na ordem em que aparecem na tela, da esquerda pro topo.
  static List<String> order(PaneNode? root) {
    final out = <String>[];
    void walk(PaneNode node) {
      if (node is PaneLeaf) {
        out.add(node.tabId);
        return;
      }
      for (final child in (node as PaneSplit).children) {
        walk(child);
      }
    }

    if (root != null) walk(root);
    return out;
  }

  static bool has(PaneNode? root, String tabId) => _leaf(root, tabId) != null;

  static int count(PaneNode? root) => order(root).length;

  /// Põe [tabId] no painel que hoje mostra [targetId].
  static void swap(PaneNode? root, String targetId, String tabId) {
    _leaf(root, targetId)?.tabId = tabId;
  }

  /// Corta o painel [targetId] e encaixa [tabId] no lado pedido.
  ///
  /// Cair no mesmo sentido do corte em que o alvo já está não cria um corte
  /// dentro do outro: vira mais uma coluna na mesma fileira, tirada da metade
  /// do espaço de quem recebeu o drop. É o que faz três painéis lado a lado
  /// serem três painéis lado a lado, e não um ao lado de um par.
  static PaneNode insert(
    PaneNode root, {
    required String tabId,
    required String targetId,
    required DropSide side,
  }) {
    final leaf = PaneLeaf(tabId);
    if (root is PaneLeaf) {
      if (root.tabId != targetId) return root;
      return PaneSplit(side.axis, side.leading ? [leaf, root] : [root, leaf], [0.5, 0.5]);
    }
    _insert(root as PaneSplit, leaf, targetId, side);
    return root;
  }

  static bool _insert(PaneSplit split, PaneLeaf leaf, String targetId, DropSide side) {
    for (var i = 0; i < split.children.length; i++) {
      final child = split.children[i];
      if (child is PaneSplit) {
        if (_insert(child, leaf, targetId, side)) return true;
        continue;
      }
      if ((child as PaneLeaf).tabId != targetId) continue;
      if (split.axis == side.axis) {
        final at = side.leading ? i : i + 1;
        final share = split.weights[i] / 2;
        split.weights[i] = share;
        split.children.insert(at, leaf);
        split.weights.insert(at, share);
      } else {
        split.children[i] = PaneSplit(side.axis, side.leading ? [leaf, child] : [child, leaf], [
          0.5,
          0.5,
        ]);
      }
      return true;
    }
    return false;
  }

  /// Tira o painel da tela e devolve a raiz que sobrou.
  ///
  /// Um corte que ficou com um filho só deixa de ser um corte — senão a árvore
  /// juntaria camadas invisíveis a cada painel fechado, e o próximo drop cairia
  /// dentro de uma delas. O espaço do que saiu vai pros vizinhos na proporção
  /// que eles já tinham entre si.
  static PaneNode? remove(PaneNode? root, String tabId) {
    if (root == null) return null;
    if (root is PaneLeaf) return root.tabId == tabId ? null : root;

    final split = root as PaneSplit;
    for (var i = 0; i < split.children.length; i++) {
      final child = split.children[i];
      final left = remove(child, tabId);
      // Nada mudou nesse ramo: `remove` devolve o mesmo nó quando não achou.
      if (identical(left, child)) continue;
      if (left == null) {
        split.children.removeAt(i);
        final freed = split.weights.removeAt(i);
        _spread(split.weights, freed);
      } else {
        split.children[i] = left;
        _absorb(split, i);
      }
      break;
    }
    if (split.children.length == 1) return split.children.first;
    return split;
  }

  /// Um corte que desabou dentro de outro do mesmo sentido é o mesmo corte:
  /// `linha[a, linha[b, c]]` é `linha[a, b, c]`, com o espaço do meio
  /// repartido entre b e c como estava lá dentro.
  static void _absorb(PaneSplit split, int i) {
    final child = split.children[i];
    if (child is! PaneSplit || child.axis != split.axis) return;
    final share = split.weights[i];
    split.children.removeAt(i);
    split.weights.removeAt(i);
    for (var k = 0; k < child.children.length; k++) {
      split.children.insert(i + k, child.children[k]);
      split.weights.insert(i + k, share * child.weights[k]);
    }
  }

  static void _spread(List<double> weights, double freed) {
    final sum = weights.fold<double>(0, (a, b) => a + b);
    if (weights.isEmpty) return;
    if (sum <= 0) {
      for (var i = 0; i < weights.length; i++) {
        weights[i] = 1 / weights.length;
      }
      return;
    }
    for (var i = 0; i < weights.length; i++) {
      weights[i] += freed * weights[i] / sum;
    }
  }

  /// Arrasta a alça entre os filhos [gutter] e `gutter + 1`.
  ///
  /// [delta] e [total] em pixels; o que fica guardado é fração, então a mesma
  /// arrastada vale o mesmo numa janela de qualquer tamanho. Passar do fim
  /// para: um painel espremido até sumir não teria como voltar, já que a alça
  /// que o traria de volta é a borda dele.
  static void resize(PaneSplit split, int gutter, double delta, double total) {
    if (gutter < 0 || gutter + 1 >= split.children.length || total <= 0) return;
    final floor = (minFor(split.axis) / total).clamp(0.0, 0.45);
    final a = split.weights[gutter];
    final b = split.weights[gutter + 1];
    final lower = floor - a;
    final upper = b - floor;
    if (lower > upper) return;
    final moved = (delta / total).clamp(lower, upper);
    if (moved == 0) return;
    split.weights[gutter] = a + moved;
    split.weights[gutter + 1] = b - moved;
  }

  static PaneLeaf? _leaf(PaneNode? node, String tabId) {
    if (node == null) return null;
    if (node is PaneLeaf) return node.tabId == tabId ? node : null;
    for (final child in (node as PaneSplit).children) {
      final found = _leaf(child, tabId);
      if (found != null) return found;
    }
    return null;
  }

  // --- disco --------------------------------------------------------------

  /// A árvore em json. Uma folha é o índice do painel na lista salva — um
  /// número, porque um id de sessão não sobrevive ao fechamento da janela.
  ///
  /// [indexOf] devolve -1 pro painel que não foi salvo (um que já morreu, por
  /// exemplo); a folha some e o corte se fecha em volta, do mesmo jeito que
  /// fecharia na tela.
  static Object? toJson(PaneNode? node, int Function(String tabId) indexOf) {
    if (node == null) return null;
    if (node is PaneLeaf) {
      final i = indexOf(node.tabId);
      return i < 0 ? null : i;
    }
    final split = node as PaneSplit;
    final children = <Object>[];
    final weights = <double>[];
    for (var i = 0; i < split.children.length; i++) {
      final json = toJson(split.children[i], indexOf);
      if (json == null) continue;
      children.add(json);
      weights.add(split.weights[i]);
    }
    if (children.isEmpty) return null;
    if (children.length == 1) return children.first;
    _normalize(weights);
    return {'axis': split.axis.name, 'weights': weights, 'children': children};
  }

  /// A volta: [tabIdAt] dá o id de quem foi restaurado naquele índice, e null
  /// pro painel que não voltou (a pasta sumiu, o cwd não existe mais).
  static PaneNode? fromJson(Object? json, String? Function(int index) tabIdAt) {
    if (json is int) {
      final id = tabIdAt(json);
      return id == null ? null : PaneLeaf(id);
    }
    if (json is! Map) return null;
    final raw = (json['children'] as List?) ?? const [];
    final saved = (json['weights'] as List?) ?? const [];
    final children = <PaneNode>[];
    final weights = <double>[];
    for (var i = 0; i < raw.length; i++) {
      final node = fromJson(raw[i], tabIdAt);
      if (node == null) continue;
      children.add(node);
      weights.add(i < saved.length ? (saved[i] as num).toDouble() : 1);
    }
    if (children.isEmpty) return null;
    if (children.length == 1) return children.first;
    _normalize(weights);
    return PaneSplit(
      json['axis'] == PaneAxis.column.name ? PaneAxis.column : PaneAxis.row,
      children,
      weights,
    );
  }

  static void _normalize(List<double> weights) {
    final sum = weights.fold<double>(0, (a, b) => a + b);
    if (sum <= 0) {
      for (var i = 0; i < weights.length; i++) {
        weights[i] = 1 / weights.length;
      }
      return;
    }
    for (var i = 0; i < weights.length; i++) {
      weights[i] = weights[i] / sum;
    }
  }
}
