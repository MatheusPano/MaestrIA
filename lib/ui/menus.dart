import 'package:flutter/material.dart';

import '../theme.dart';

/// As peças dos menus da lateral: a linha com desenho e nome, e a linha que
/// abre um segundo menu ao lado quando o ponteiro para nela.
///
/// Estavam soltas dentro de `sidebar.dart` porque só o + as usava. Agora o +,
/// o botão direito de um projeto e o de uma worktree oferecem o mesmo bloco
/// -- abrir algo aqui --, e o bloco é escrito uma vez: ver `openHereItems`.
///
/// O submenu não é `showMenu` de novo. Um segundo menu modal traz uma barreira
/// que engole o ponteiro, e o menu de baixo fica surdo ao hover: ir pra outra
/// linha não fecharia o submenu, e é justamente isso que ele tem que fazer.
/// Então ele é uma [OverlayEntry] crua por cima de tudo -- sem barreira, sem
/// rota --, e quem escolhe uma linha dela fecha o menu de baixo pelo
/// [Navigator] do próprio item, que é o que um [PopupMenuItem] já faz.

/// O submenu aberto, se houver. Um só: nesta janela nunca há dois menus
/// abertos ao mesmo tempo, então as linhas não precisam de um canal pra
/// combinar entre si -- basta o lugar onde a aberta se anota.
OverlayEntry? _open;

/// Quem o abriu, pra que o hover repetido na mesma linha não o feche e
/// reabra a cada pixel que o ponteiro anda dentro dela.
Object? _owner;

void _closeSubmenu() {
  _open?.remove();
  _open = null;
  _owner = null;
}

/// A geometria de um menu, escrita num lugar só.
///
/// [mxMenuWidth] é o piso da largura de um menu e a largura exata de um
/// submenu -- ele se posiciona antes de existir (ver
/// [_MxSubmenuItemState._openSubmenu]) e pra isso precisa saber quanto vai
/// ocupar. Sem piso cada menu ficava do tamanho do texto dele: "colar" e
/// "limpar concluídos" abriam duas fitas de larguras diferentes,
/// e o menu deixava de ter forma própria.
///
/// [_pad] é o vão lateral das duas linhas -- a do menu e a do submenu. Eram
/// 12 e 16, o que desalinhava por quatro pixels o nome de uma linha e o nome
/// da linha que ela abriu.
///
/// [_rowHeight] é alvo de mouse antes de ser espaçamento: a linha inteira é
/// clicável, então a altura dela *é* a mira. Em 30 o menu ficava compacto e
/// era preciso ter pontaria pra acertar a linha certa entre duas vizinhas --
/// e o único jeito de errar num menu é escolher a linha de baixo. O que fazia
/// o menu comprido era a contagem de linhas, e disso quem cuida são os riscos
/// que os dividem em blocos, não o aperto de cada uma.
const double mxMenuWidth = 216;
const double _rowHeight = 36;
const double _tallRow = 48;
const double _pad = 14;

/// A calha do desenho, à esquerda do nome.
///
/// Reservada mesmo na linha que não tem desenho: é ela que faz um menu de dez
/// linhas ler como uma coluna de nomes, em vez de nomes que começam em dois
/// lugares diferentes dependendo de haver glifo ou não.
const double _glyph = 16;

/// Um menu de contexto onde o ponteiro estava.
///
/// Os nove menus da janela repetiam as mesmas quatro linhas -- pegar o
/// overlay, virar o ponto num [RelativeRect], dizer a cor, e nada de largura
/// nem de corte. Uma definição só, porque a diferença entre eles é a lista de
/// linhas e mais nada: é isso que faz o menu do painel e o da pasta lerem
/// como o mesmo objeto aberto sobre coisas diferentes.
///
/// A cor e o canto vêm do tema (ver `Mx.theme`).
Future<T?> mxMenu<T>(
  BuildContext context, {
  required Offset at,
  required List<PopupMenuEntry<T>> items,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
    // O canto arredondado do tema só se vê com o corte: sem ele o realce da
    // primeira e da última linha passa por cima da curva, e reaparece nos
    // quatro cantos o quadrado que o tema tirou.
    clipBehavior: Clip.antiAlias,
    // O teto é maior que os 280 do Material: um nome de branch numa linha de
    // worktree cabe, em vez de ser cortado num menu que tinha espaço de sobra
    // na tela.
    constraints: const BoxConstraints(minWidth: mxMenuWidth, maxWidth: 340),
    items: items,
  );
}

/// O risco que separa dois blocos de um menu.
///
/// Recuado dos dois lados: encostado na borda ele risca a curva do canto e
/// devolve ao menu a aparência de tabela que o arredondamento tirou.
PopupMenuDivider mxDivider() =>
    PopupMenuDivider(height: 9, color: Mx.border, indent: _pad, endIndent: _pad);

/// Uma linha de menu com desenho e nome -- o glifo é o que fazia as ofertas
/// do + serem distinguíveis de relance, e ele ficou.
///
/// Fecha o submenu ao ser apontada: com um aberto ao lado, apontar outra
/// linha é dizer que não era aquilo que você queria.
PopupMenuItem<String> mxItem(
  String value, {
  required String label,
  String? subtitle,
  Color? subtitleColor,
  Widget? glyph,
  Color? color,
  Widget? trailing,
  String? chord,
  bool enabled = true,
}) => PopupMenuItem(
  value: value,
  height: subtitle == null ? _rowHeight : _tallRow,
  padding: const EdgeInsets.symmetric(horizontal: _pad),
  enabled: enabled,
  child: MouseRegion(
    onEnter: (_) => _closeSubmenu(),
    child: mxMenuRow(
      label: label,
      subtitle: subtitle,
      subtitleColor: subtitleColor,
      // O nome de uma linha desligada apaga sozinho -- é o estado
      // `disabled` do `labelTextStyle` do tema --, mas o glifo não sabe
      // disso: aceso ao lado de um nome apagado, ele é a única parte da
      // linha que continua parecendo clicável.
      glyph: enabled || glyph == null ? glyph : Opacity(opacity: 0.45, child: glyph),
      color: color,
      trailing: trailing,
      chord: chord,
    ),
  ),
);

/// O corpo de uma linha: desenho à esquerda, nome, e o que quem chama quiser
/// pendurar no fim. Compartilhado pelas linhas do menu e pelas do submenu,
/// porque um submenu que não se pareça com o menu que o abriu é outro menu.
///
/// [chord] é a tecla que faz o mesmo que a linha, dita à direita e apagada:
/// escrita no meio do nome ("copiar  ⌘C") ela era mais uma palavra da frase,
/// e num menu de dez linhas as teclas não formavam coluna nenhuma.
///
/// [subtitle] é a segunda linha de quem precisa de duas -- uma worktree só se
/// identifica pelo branch, e o branch é justo a metade que não cabia ao lado
/// do nome.
Widget mxMenuRow({
  required String label,
  String? subtitle,
  Color? subtitleColor,
  Widget? glyph,
  Color? color,
  Widget? trailing,
  String? chord,
}) => Row(
  children: [
    SizedBox(width: _glyph, child: glyph == null ? null : Center(child: glyph)),
    const SizedBox(width: 9),
    Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, height: 1.2, color: color),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: Mx.mono,
                fontSize: 10.5,
                height: 1.2,
                color: subtitleColor ?? Mx.fgFaint,
              ),
            ),
          ],
        ],
      ),
    ),
    if (chord != null) ...[
      const SizedBox(width: 10),
      Text(chord, style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
    ],
    if (trailing != null) ...[const SizedBox(width: 8), trailing],
  ],
);

/// Uma linha do submenu: o que ela mostra e o que o menu devolve se ela for
/// escolhida.
class MxSubItem {
  const MxSubItem({
    required this.value,
    required this.label,
    this.glyph,
    this.color,
    this.divided = false,
  });

  /// Volta de `showMenu` como se tivesse sido clicada no menu de cima: pra
  /// quem chamou, o submenu não existe.
  final String value;
  final String label;
  final Widget? glyph;
  final Color? color;

  /// Um risco em cima desta linha: o que separa os programas do usuário da
  /// oferta de ensinar mais um.
  final bool divided;
}

/// A linha que abre um submenu ao lado quando o ponteiro para nela.
///
/// Clicar também abre -- uma linha com seta que não faz nada ao ser clicada
/// parece quebrada, e o ponteiro que veio pelo teclado ou pelo trackpad de
/// um toque só nem passou por cima dela.
class MxSubmenuItem extends PopupMenuEntry<String> {
  const MxSubmenuItem({
    super.key,
    required this.label,
    required this.items,
    this.glyph,
  });

  final String label;
  final Widget? glyph;

  /// Montadas na hora de abrir e não na de construir o menu: entre um e outro
  /// o usuário pode ter criado um programa no diálogo que a última linha abre.
  final List<MxSubItem> Function() items;

  @override
  double get height => _rowHeight;

  /// Nenhum valor: escolher no submenu fecha o menu com o valor da linha de
  /// lá, e esta linha nunca é a escolhida.
  @override
  bool represents(String? value) => false;

  @override
  State<MxSubmenuItem> createState() => _MxSubmenuItemState();
}

class _MxSubmenuItemState extends State<MxSubmenuItem> {
  /// A animação da rota do menu que contém esta linha, se ela for uma rota.
  Animation<double>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // O menu de cima indo embora leva o submenu com ele. `dispose` só chega
    // depois da animação de saída, e um submenu flutuando sozinho por um
    // décimo de segundo depois do menu sumir se vê.
    final animation = ModalRoute.of(context)?.animation;
    if (animation == _route) return;
    _route?.removeListener(_onRouteAnimation);
    _route = animation?..addListener(_onRouteAnimation);
  }

  void _onRouteAnimation() {
    if (_route?.status == AnimationStatus.reverse && _owner == this) _closeSubmenu();
  }

  @override
  void dispose() {
    _route?.removeListener(_onRouteAnimation);
    if (_owner == this) _closeSubmenu();
    super.dispose();
  }

  void _openSubmenu() {
    if (_owner == this) return;
    _closeSubmenu();

    final rows = widget.items();
    if (rows.isEmpty) return;

    final overlay = Overlay.of(context, rootOverlay: true);
    final screen = (overlay.context.findRenderObject() as RenderBox).size;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay.context.findRenderObject());

    // Encostado na borda do menu e não a um vão dele: o ponteiro andando da
    // linha até o submenu não pode atravessar um pedaço de tela que não é de
    // nenhum dos dois.
    final tall = rows.length * _rowHeight + rows.where((r) => r.divided).length * 9 + 10;
    var left = origin.dx + box.size.width - 4;
    if (left + mxMenuWidth > screen.width - 8) left = origin.dx - mxMenuWidth + 4;
    var top = origin.dy - 5;
    if (top + tall > screen.height - 8) top = screen.height - 8 - tall;

    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: left.clamp(8.0, screen.width - mxMenuWidth - 8),
        top: top.clamp(8.0, screen.height - tall - 8),
        width: mxMenuWidth,
        child: _Submenu(rows: rows, onPick: _pick),
      ),
    );
    _open = entry;
    _owner = this;
    overlay.insert(entry);
  }

  /// Fecha o menu de cima devolvendo o que foi escolhido aqui, pelo
  /// [Navigator] desta linha -- o mesmo caminho do `handleTap` de um
  /// [PopupMenuItem]. Quem chamou `showMenu` recebe o valor e nem sabe que
  /// veio de um segundo menu.
  void _pick(String value) {
    _closeSubmenu();
    Navigator.pop<String>(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _openSubmenu(),
      child: InkWell(
        onTap: _openSubmenu,
        child: Container(
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: _pad),
          alignment: Alignment.centerLeft,
          child: mxMenuRow(
            label: widget.label,
            glyph: widget.glyph,
            trailing: Icon(Icons.chevron_right, size: 14, color: Mx.fgFaint),
          ),
        ),
      ),
    );
  }
}

/// O painel do submenu: o desenho de um menu, sem ser um.
class _Submenu extends StatelessWidget {
  const _Submenu({required this.rows, required this.onPick});

  final List<MxSubItem> rows;
  final void Function(String value) onPick;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Mx.bgActive,
      // O mesmo canto, a mesma borda e a mesma sombra do menu que o abriu --
      // ver `popupMenuTheme` em `Mx.theme`. Ele não é um `showMenu`, então
      // nada disso lhe chega de graça: tem que ser dito outra vez, igual.
      elevation: 12,
      shadowColor: Mx.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Mx.radius),
        side: BorderSide(color: Mx.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in rows) ...[
              if (row.divided)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: _pad),
                  child: Divider(height: 1, thickness: 1, color: Mx.border),
                ),
              InkWell(
                onTap: () => onPick(row.value),
                child: Container(
                  height: _rowHeight,
                  padding: const EdgeInsets.symmetric(horizontal: _pad),
                  alignment: Alignment.centerLeft,
                  child: mxMenuRow(label: row.label, glyph: row.glyph, color: row.color),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
