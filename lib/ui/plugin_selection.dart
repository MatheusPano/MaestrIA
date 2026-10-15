import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// O `Selectable` de `import maestria;`: uma área de seleção só pra tudo o que
/// está dentro -- arrastar atravessa parágrafos, balões e mensagens, e o ⌘C
/// copia o trecho inteiro.
///
/// A área do Flutter junta os pedaços selecionados sem nada entre eles: dois
/// parágrafos, ou uma pergunta e a resposta, viravam uma linha só,
/// "corrige o loginAchei o problema". Aqui cada pedaço que começa embaixo do
/// anterior vai numa linha nova, e o que está ao lado dele (o "•" de um item de
/// lista e o texto do item) fica na mesma linha, com um espaço.
class PluginSelectable extends StatelessWidget {
  const PluginSelectable({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SelectionArea(child: SelectionLines(child: child));
}

/// Junta o que foi selecionado lá dentro em linhas, pela posição na tela (ver
/// [PluginSelectable]). Sozinho, é o `SelectionLines` de `import maestria;`:
/// pro conteúdo de dentro de uma área rolável, que tem a seleção dela -- o
/// `Selectable` fica por fora da rolagem (assim o arraste rola sozinho), e este,
/// por dentro, em volta das mensagens.
class SelectionLines extends StatefulWidget {
  const SelectionLines({super.key, required this.child});

  final Widget child;

  @override
  State<SelectionLines> createState() => _SelectionLinesState();
}

class _SelectionLinesState extends State<SelectionLines> {
  final LinesSelectionDelegate _delegate = LinesSelectionDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionContainer(delegate: _delegate, child: widget.child);
}

/// O delegado de [SelectionLines]: o de sempre do Flutter, mas o texto copiado
/// separa os pedaços por linha.
@visibleForTesting
class LinesSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final buffer = StringBuffer();
    Rect? last;
    for (final selectable in selectables) {
      final content = selectable.getSelectedContent();
      if (content == null || content.plainText.isEmpty) continue;
      final rect = MatrixUtils.transformRect(selectable.getTransformTo(null), Offset.zero & selectable.size);
      if (last != null) buffer.write(joinBetween(last, rect));
      buffer.write(content.plainText);
      last = rect;
    }
    return buffer.isEmpty ? null : SelectedContent(plainText: buffer.toString());
  }

  /// O que vai entre dois pedaços: linha nova quando o segundo começa embaixo
  /// do primeiro; um espaço quando estão lado a lado.
  @visibleForTesting
  static String joinBetween(Rect before, Rect after) => after.top >= before.bottom - 2 ? '\n' : ' ';
}
