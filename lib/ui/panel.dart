import 'package:flutter/material.dart';

import '../theme.dart';

/// A floating panel: the one shape every region of the window is made of.
///
/// The window paints [Mx.canvas] and each region — sidebar, terminal, status
/// bar — sits on it as its own card with a gutter around it, the way VS Code
/// detaches its panels. The seam between two regions is a gap, so nothing
/// needs a 1px divider to be told apart.
class MxPanel extends StatelessWidget {
  const MxPanel({
    super.key,
    required this.child,
    this.color,
    this.focused = false,
    this.showFocus = false,
    this.tint,
    this.radius = Mx.radius,
  });

  final Widget child;

  /// Defaults to [Mx.bg] — resolved in [build], not in the constructor, so the
  /// panel follows a theme change like everything else.
  final Color? color;

  /// The accent outline, for telling two open panes apart. Only drawn when
  /// [showFocus] asks for it, so a lone pane is not permanently ringed.
  final bool focused;
  final bool showFocus;

  /// A cor escolhida pro painel que este cartão desenha, quando ele tem uma.
  /// Ver [MxTint] e [MxTab.tint].
  ///
  /// Pinta a borda, e o anel de foco passa na frente dela: a cor diz *quem* é
  /// este painel, o anel diz onde o teclado está -- e quando as duas querem a
  /// mesma borda, quem responde à tecla que você acabou de apertar ganha. Num
  /// painel só na tela não há anel nenhum (ver `panes.dart`), e é justamente
  /// aí que a cor é a única coisa que separa duas sessões que se sucedem no
  /// mesmo retângulo.
  final Color? tint;

  final double radius;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    final ring = showFocus && focused;
    final edge = ring ? Mx.accent.withValues(alpha: 0.65) : (tint ?? Mx.border);
    return Container(
      // The child fills the card — a header strip has to stop at the corner.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? Mx.bg,
        borderRadius: shape,
        boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 12, offset: const Offset(0, 3))],
      ),
      // In front of the child, not behind it: an opaque header would otherwise
      // paint over the inner half of a background border.
      foregroundDecoration: BoxDecoration(
        borderRadius: shape,
        // O fio grosso é da borda que quer ser vista -- o anel de foco e a
        // cor escolhida. Ele não custa layout: esta borda é
        // `foregroundDecoration`, desenhada por cima do miolo em vez de
        // reservar espaço nele. A cor vai cheia e em 2: a 60% de alpha num
        // fio de 1.4 ela era um contorno que só se via procurando, e uma cor
        // que precisa ser procurada não serve pra separar dois painéis de
        // relance.
        border: Border.all(color: edge, width: tint != null ? 2 : (ring ? 1.4 : 1)),
      ),
      child: child,
    );
  }
}

/// O fundo do cabeçalho de um painel, com a cor dele quando ele tem uma.
///
/// Uma função e não uma constante porque são dois cabeçalhos -- o do terminal
/// e o do leitor -- e eles têm que ser o mesmo desenho: dois tons de faixa no
/// mesmo lugar da janela leem como bug, não como distinção.
///
/// A cor entra como banho por cima do fundo da faixa, e não no lugar dele --
/// mesma conta da linha da lateral (ver `_RowState`). O que se quer é o *tom*
/// da faixa, não uma faixa colorida: o nome escrito nela continua tendo o
/// contraste que tinha.
BoxDecoration paneHeaderBox(Color? tint) => BoxDecoration(
  color: tint == null
      ? Mx.bgSidebar
      : Color.alphaBlend(tint.withValues(alpha: 0.34), Mx.bgSidebar),
  // O fio de baixo é onde a cor aparece inteira, sem banho por cima: o fundo
  // da faixa tem o nome escrito nele e não pode chegar na cor cheia em paleta
  // nenhuma, então o bloco sólido vai embaixo dele, na largura toda.
  //
  // Embaixo e não na lateral: uma lombada à esquerda é um retângulo reto
  // encostando na curva do cartão, e o canto ficava com um degrau. Este corre
  // onde o cartão é reto, de borda a borda, e não tem canto pra brigar.
  border: Border(
    bottom: tint == null
        ? BorderSide(color: Mx.border)
        : BorderSide(color: tint, width: 3),
  ),
);

/// O nome do painel, no cabeçalho.
///
/// Um estilo num lugar só, e maior e mais pesado que o resto da faixa de
/// propósito. O cabeçalho tem oito coisas dentro (fichas de projeto e branch,
/// contadores, subtítulo, botões) e o nome era do mesmo tamanho de todas elas
/// -- informação disponível, que não é a mesma coisa que informação percebida.
/// Numa janela onde os painéis se sucedem no mesmo retângulo, o nome é a única
/// coisa da faixa que responde "com quem eu estou falando".
const paneTitleStyle = TextStyle(fontWeight: FontWeight.w700, fontSize: 15);

/// A tecla que abre este painel, dita no cabeçalho dele.
///
/// A mesma que a linha da lateral mostra (ver `_TabRow`), e aqui pelo mesmo
/// motivo que o nome: é o segundo jeito de reconhecer um painel sem ler nada
/// -- e o único da faixa que também *ensina* como voltar pra ele.
///
/// Recebe o índice já resolvido em vez do painel e da store: este arquivo é o
/// desenho de um cartão, e não precisa saber o que é uma sessão pra escrever
/// "⌘3".
class PaneKeyHint extends StatelessWidget {
  const PaneKeyHint({super.key, required this.index});

  /// A posição do painel na lista, contada de zero -- ou -1 pra quem não está
  /// nela. Do décimo em diante não há tecla, e aí não há nada pra dizer.
  final int index;

  @override
  Widget build(BuildContext context) {
    if (index < 0 || index >= 9) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 2),
      child: Text(
        '⌘${index + 1}',
        style: TextStyle(fontFamily: Mx.mono, fontSize: 10.5, color: Mx.fgFaint),
      ),
    );
  }
}
